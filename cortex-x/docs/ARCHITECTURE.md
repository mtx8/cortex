# CORTEX X — Architecture

A ground-up rebuild of CORTEX as a two-process, all-native platform:

```
┌─────────────────────────── macOS app (SwiftUI) ───────────────────────────┐
│  Chart engine (Canvas/Metal)  ·  Copilot  ·  Agent feed  ·  Risk HUD      │
└───────────────────────────────△ ws://127.0.0.1:9601 ▽─────────────────────┘
┌──────────────────────────── cortexd (Rust) ───────────────────────────────┐
│ cx-server   websocket gateway: events out, commands in, snapshots         │
│ cx-agents   AI mesh: analyst · macro sentinel · risk officer · strategist │
│             (LLM strategic loop — NEVER in the execution hot path)        │
│ cx-strategy strategy runtime: momentum · mean-rev · breakout → fusion     │
│ cx-risk     ECHO: kill switch · pre-trade · drawdown clocks · caution     │
│ cx-oms      orders · paper exchange · positions · PnL                     │
│ cx-md       feeds: Coinbase WS live · synthetic fallback · bars · backfill│
│ cx-ta       streaming indicators & regime detection (pure)                │
│ cx-core     THE CONTRACT: types · events · bus · kill · config · egress   │
└────────────────────────────────────────────────────────────────────────────┘
```

## Invariants (carried forward from CORTEX v1, now enforced in Rust)

1. **Bus-only nervous system.** Squadron crates depend on `cx-core` alone and
   speak exclusively through `Bus` (`Arc<EngineEvent>` broadcast). No
   cross-squadron imports — the compiler enforces what v1 asked of discipline.
2. **Two-phase kill switch.** Phase 1 is a synchronous in-memory atomic read
   on every order path; engagement is instant and network-free. Phase 2
   (flatten, broadcast, audit) rides the bus afterwards.
3. **Tighten-only caution.** Any agent may raise caution on a symbol or
   globally; caution can only shrink position sizes (bounded multiplier,
   floored, TTL-bounded, NaN-safe). No signal can ever grow risk through the
   caution channel, approve a rejected order, or weaken the kill switch.
4. **Single order path.** Signal → TradePipeline → RiskEngine.evaluate →
   OMS. There is no second door.
5. **Autonomy dial with CRITICAL bypass.** Manual / suggest-only / semi /
   full-auto gates *new* risk. Safety actions (kill, flatten, throttle)
   bypass the dial at every level.
6. **LLM out of the hot path.** The strategist runs on a slow cadence
   (default 300 s), reads the context ledger, and may only nudge strategy
   posture and caution — it never places orders directly.
7. **Hardened egress.** All REST leaves through one chokepoint: https-only,
   exact-host allowlist, no redirects, byte-capped, secret-free errors.
8. **Secrets** live in `~/.cortex/secrets.toml` or the environment. The
   `Secret` type cannot be Debug-printed.

## Data flow

- **Hot path (µs–ms):** Coinbase WS → tick parse → bus + bar aggregation →
  strategies (pure indicator math) → pipeline → risk (sync) → paper OMS →
  fills/positions/account back onto the bus → UI.
- **Strategic path (seconds–minutes):** context ledger accumulates bars,
  signals, fills, risk states, macro snapshots → strategist LLM (local-first:
  Ollama if configured, else Anthropic API, else heuristic) → posture +
  caution adjustments + written rationale (visible in the app as thoughts).
- **Macro path (hours):** Treasury par-yield curve (2s10s / 3m10s), ECB
  reference FX via Frankfurter — keyless, resilient, cached.

## Wire protocol (`ws://127.0.0.1:9601`)

Server → client: `{"type": "hello"| "snapshot" | <EngineEvent tag>, ...}` —
every `EngineEvent` serializes with a `type` tag (`tick`, `bar`, `order_update`,
`fill`, `position`, `account`, `risk`, `thought`, `signal`, `macro`,
`feed_status`, `ai_answer`). Client → server: `Command` JSON with a `cmd` tag
(`place_order`, `cancel_order`, `set_kill_switch`, `set_autonomy`,
`set_strategy_enabled`, `flatten_all`, `ask_ai`, `sync`).

Rust source of truth: `engine/crates/cx-core/src/events.rs` and `command.rs`.
The Swift models mirror these exactly.

## Why Rust (not C++ / not Mojo)

Same performance class as C++ with memory safety guaranteed at compile time —
in a system that holds money, UB is not a tolerable failure mode. The async
ecosystem (tokio) matches an event-driven trading engine exactly. Mojo remains
immature for production servers; there is no Python in the runtime at all.
