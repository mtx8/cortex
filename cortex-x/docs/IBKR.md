# CORTEX X — Interactive Brokers adapter (PAPER-FIRST)

The `cx-broker` crate is the live-trading routing layer. It is **paper-first**:
with no `[broker]` config the engine behaves exactly as it does today (the
built-in paper exchange), and there is **zero** reach toward a real broker
until you explicitly opt in. This runbook covers installing IB Gateway / TWS,
the config, and a go-live checklist.

> **Honesty up front.** The adapter's safe core — the `Broker` trait, the paper
> broker, the `OrderIntent -> IBKR` translation, the LIVE hard-limit guard, the
> config gates, and the fallback-to-paper — is compiled and unit-tested with no
> gateway. The actual socket layer (`ibapi` 3.3) is compiled behind the
> `ibkr-live` feature and is compile-verified, but **end-to-end paper/live
> verification requires your own running Gateway and account**. Validate on a
> paper account first (see the checklist).

---

## Architecture in one paragraph

Every order still travels the single existing path:

```
fusion / command  ->  RiskEngine::evaluate  ->  kill switch  ->  reduce-only clamp
                                                                        |
                                                                        v
                                                          active Broker sink (place)
                                                   paper: cx-oms   |   ibkr: IbkrBroker
```

The broker is only ever a **sink downstream of risk approval** — never a
bypass. In `ibkr` mode the adapter adds its own real-money guard (below) **on
top of** the RiskEngine; it can only tighten, never relax.

The IBKR link is a **direct localhost TCP socket** to your own IB Gateway /
TWS. It deliberately does **not** go through CORTEX's hardened HTTP egress
chokepoint — that chokepoint governs *public* market-data / AI REST calls; a
broker socket to software you run locally is a different trust domain. Your
account id is held in `cx_core::config::Secret` and is **never** logged.

---

## 1. Install IB Gateway (or TWS) and enable the API

1. Install **IB Gateway** (lighter, headless-friendly — recommended) or
   **Trader Workstation (TWS)** from Interactive Brokers.
2. Log in to the account you want CORTEX to use — **use a PAPER login first**.
3. Enable the API socket:
   - TWS: *File → Global Configuration → API → Settings*.
   - Gateway: *Configure → Settings → API → Settings*.
   - Check **"Enable ActiveX and Socket Clients"**.
   - Leave **"Read-Only API" unchecked** only when you actually intend to place
     orders (keep it checked while you are just wiring up data).
   - Under **"Trusted IPs"** ensure `127.0.0.1` is allowed. CORTEX only ever
     connects to localhost.
4. Note the **Socket port** for the session you are logged into (see below) and
   set it as `broker.ibkr_port`.

### Ports — paper vs live (this matters)

| Port   | Application | Account   | CORTEX treats as |
| ------ | ----------- | --------- | ---------------- |
| `7497` | TWS         | **PAPER** | safe default     |
| `4002` | IB Gateway  | **PAPER** | safe             |
| `7496` | TWS         | **LIVE**  | real money — gated |
| `4001` | IB Gateway  | **LIVE**  | real money — gated |

The two LIVE ports (`7496`, `4001`) require `broker.allow_live = true`. A live
port with `allow_live = false` is a **hard config error** at load AND the
adapter refuses to connect — it is never a silent live reach.

---

## 2. Config — the `[broker]` block

Add to `~/.cortex/secrets.toml`. Every field shown with its default; a missing
`[broker]` section means "paper", identical to today.

```toml
[broker]
mode                       = "paper"      # "paper" (default) | "ibkr"
ibkr_host                  = "127.0.0.1"  # your local Gateway/TWS
ibkr_port                  = 7497         # 7497 TWS paper / 4002 gw paper (DEFAULT is paper)
ibkr_client_id             = 11           # API client id
ibkr_account               = ""           # e.g. "DU1234567" (paper) / "U1234567" (live) — NEVER logged
ibkr_route                 = "SMART"      # "SMART" or a direct venue (ARCA/ISLAND/IEX/NYSE...) for true DMA
allow_live                 = false        # the real-money master switch
max_live_order_notional    = 2000.0       # LIVE hard limit — reject any single order over this
max_live_position_notional = 5000.0       # LIVE hard limit — reject any order pushing a symbol past this
max_live_daily_loss        = 500.0        # LIVE hard limit — halt (cancel+flatten) once the day loss hits this
```

Validation (fails closed at load):

- `mode` must be `"paper"` or `"ibkr"`.
- If `ibkr_port` is a LIVE port (`7496`/`4001`) then `allow_live` **must** be
  `true`, or startup errors loudly.
- `max_live_order_notional`, `max_live_position_notional`, and
  `max_live_daily_loss` must each be **finite and > 0** (a NaN/0/negative cap
  can never defeat the guard).

### Direct market access (DMA)

Set `ibkr_route` to a direct exchange code (e.g. `"ARCA"`, `"ISLAND"`,
`"IEX"`, `"NYSE"`) to route stock orders straight to that venue instead of
IBKR SmartRouting. Order types map as: `Market → MKT`, `Limit → LMT`,
`Stop → STP` (trigger in `auxPrice`), `StopLimit → STP LMT` (trigger in
`auxPrice`, cap in `lmtPrice`).

---

## 3. Build the daemon with the live socket layer

The real `ibapi` socket code compiles only behind a feature, so a pure
paper/backtest build carries no IBKR dependency:

```bash
# Paper only (default) — no ibapi dependency compiled:
cargo build --release -p cortexd

# With the real IBKR socket layer:
cargo build --release -p cortexd --features ibkr-live
```

If you set `mode = "ibkr"` but built **without** `--features ibkr-live`, the
adapter reports "not compiled", logs a **critical** thought, and **falls back
to paper** — never live, never a crash.

---

## 4. Runtime safety invariants (what the adapter guarantees)

1. **Paper is the default.** No `[broker]` (or `mode="paper"`) ⇒ byte-for-byte
   today's paper engine.
2. **Risk first, always.** The adapter is a sink after `RiskEngine::evaluate`.
3. **Two gates for live.** `mode="ibkr"` **and** a live port **and**
   `allow_live=true`.
4. **Kill reaches IBKR.** Engaging the kill switch (operator or the drawdown
   clock) routes `flatten_all` to the broker: **cancel all working orders, then
   flatten every position**. The synchronous Phase-1 kill blocks new orders
   instantly, before any network.
5. **Live hard limits** (`max_live_*`) are enforced inside `place()` on top of
   the RiskEngine. Over-notional orders are rejected with a clear reason;
   breaching the daily-loss cap **halts** (cancel + flatten) and blocks new
   orders for the session (reduce-only exits still pass).
6. **Connect failure ⇒ paper.** Any connect failure (refused live port, no
   Gateway, feature not compiled) falls back to paper with a loud critical
   thought.

---

## 5. GO-LIVE CHECKLIST

Do these **in order**. Do not skip step 1.

- [ ] **1. Validate on PAPER end-to-end.** Log IB Gateway into a **paper**
      account. Set `mode="ibkr"`, `ibkr_port=7497` (or `4002`), `allow_live=false`,
      `ibkr_account="DU..."`. Start `cortexd --features ibkr-live`. Confirm in the
      logs/UI: "IBKR connected (paper account)", positions/account stream, an
      order places and fills, `flatten_all` cancels+flattens, and the kill switch
      flattens. Run for a full session.
- [ ] **2. Set the LIVE hard limits deliberately.** Choose
      `max_live_order_notional`, `max_live_position_notional`, and
      `max_live_daily_loss` for the real account. Start **small** — these are your
      real-money backstop, independent of the RiskEngine's percentage sizing.
- [ ] **3. Confirm the RiskEngine config for the live account.** Set
      `risk.*` (position pct, order notional, drawdown clocks) appropriately.
- [ ] **4. Switch to the LIVE account.** Log IB Gateway into the **live**
      account. Set `ibkr_account` to the live id (`U...`).
- [ ] **5. Flip the two live gates.** Set `ibkr_port` to the live port
      (`7496` TWS / `4001` Gateway) **and** `allow_live=true`. (Either one alone
      refuses to connect.)
- [ ] **6. Start with the smallest possible size** and one symbol. Watch the
      first live order, fill, and a manual flatten before enabling autonomy.
- [ ] **7. Keep the kill switch reachable.** Confirm the app's kill/flatten
      controls work against the live account before stepping away.

---

## 6. Runtime reconfiguration from the app (Settings)

The broker can also be configured **without restarting the engine**, from the
app's Settings, via the `set_broker_config` command:

```json
{ "cmd": "set_broker_config", "mode": "paper", "ibkr_host": "127.0.0.1",
  "ibkr_port": 7497, "ibkr_client_id": 11, "ibkr_account": "",
  "ibkr_route": "SMART", "allow_live": false, "max_live_order_notional": 2000.0,
  "max_live_position_notional": 5000.0, "max_live_daily_loss": 500.0 }
```

The fields mirror the `[broker]` block one-for-one. The engine converts the
command to the **same** `BrokerConfig` type and re-runs the **identical**
safety gates as a disk load — so nothing about this path can weaken them:

- A **LIVE port** (`7496`/`4001`) is refused without `allow_live=true`.
- `mode="ibkr"` requires an account id; a **live-looking** account (not `DU…`)
  requires `allow_live=true` regardless of port.
- Every `max_live_*` limit must be **finite and > 0**.

Behaviour is **fail-safe** and matches startup:

- **Invalid config → no change.** The request is rejected, the **previous safe
  broker keeps routing**, and a **critical** thought is published. Nothing swaps.
- **`paper` → instant.** Switching to (or between) paper swaps immediately.
- **`ibkr` → connect or fall back.** A valid `ibkr` config attempts the
  Gateway; on **any** failure it **falls back to paper** with a loud critical
  thought — never silently live, never a crash.
- **The swap is seamless.** The pipeline routes through a stable holder whose
  delegate is replaced, so the **kill switch / risk / flatten path keeps
  working** across the swap; the outgoing session is disconnected only *after*
  the new one is live. An updated `broker_status` event is published so the app
  badge reflects real money immediately.

> **No password ever transits this command.** IBKR API authentication happens
> entirely in **your** IB Gateway / TWS login — CORTEX only opens a localhost
> socket to software you are already logged into. `ibkr_account` is an **id, not
> a credential**; it is wrapped in `Secret` on the engine side, is **never
> logged**, and appears only **masked** (`U12****89`) in status.

> **Note (ibkr → ibkr).** Reconnecting IBKR at runtime with the **same**
> `ibkr_client_id` while the previous session is still up can be refused by the
> Gateway (duplicate client id); it then falls back to paper with a critical
> thought (safe). Use a different `ibkr_client_id`, or reconfigure via `paper`
> first, to hop between two live IBKR sessions.

---

## 7. Known v1 scope / gaps (be honest)

- **US equities only.** The live adapter routes `STK` orders (SMART or a direct
  venue). Crypto symbols (e.g. `BTC-USD`) are **not** routed live in v1 — they
  are refused by the adapter with a clear reason. Keep crypto on the paper /
  Coinbase path, or configure an equities-only symbol set for live.
- **Risk sizing baseline.** In live mode the RiskEngine still sizes against the
  paper OMS `equity` baseline (the configured `paper.starting_cash`). The
  adapter's `max_live_*` hard limits are the real-money backstop. Feeding IBKR
  account equity into the risk view is a documented follow-up.
- **Fill/position/account stream.** The adapter bridges IBKR **position** and
  **PnL** callbacks onto the bus (and into the daily-loss halt). A dedicated
  per-execution fill/commission bridge is a follow-up; positions and account
  PnL are already live.
- **Offline tests.** The translation, the LIVE guard (order/position notional,
  daily-loss halt), the config gates, the paper delegation, and the
  kill→cancel+flatten path are all unit-tested with **no** gateway. The socket
  round-trip is only exercised against your running Gateway.
