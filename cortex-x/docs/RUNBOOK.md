# CORTEX X — Operator Runbook

## Start / stop

```sh
# engine
cd cortex-x/engine
cargo run --release -p cortexd          # foreground; ctrl-c to stop
RUST_LOG=debug cargo run -p cortexd     # verbose

# app
cd cortex-x/app && swift run -c release
```

The engine is stateless on disk in this build: stopping it flattens nothing
(paper positions vanish with the process). Start order does not matter — the
app reconnects with backoff and re-syncs from the snapshot.

## Feeds

- Default: Coinbase public websocket (no key). Watch the `feeds` panel in the
  app sidebar: `live` (green), `synthetic` (amber) means the engine fell back
  to its internal market simulator after repeated connect failures.
- Force offline mode: `CORTEX_FEED=synthetic cargo run -p cortexd`.
- Change symbols: `CORTEX_SYMBOLS=BTC-USD,DOGE-USD cargo run -p cortexd`
  (Coinbase product ids).

## Risk controls (in-app, right side / dashboard)

| Control | Effect |
|---|---|
| Kill switch | Instant synchronous halt of every new order; only manual reduce-only and risk-flatten orders pass. Engaging is always honored; disengaging requires deliberate operator action. |
| Autonomy dial | `manual` / `suggest` (agents only propose, visible in the feed) / `semi-auto` (small orders) / `full auto`. Safety actions bypass the dial at every level. |
| Flatten all | Closes every position with reduce-only market orders. Two-step confirm. |
| Caution | Read-only gauge: agents can only tighten sizing (never loosen). TTL-bounded. |
| Drawdown clocks | Day 3% / total 10% by default: throttle begins at half the limit, halts at the limit, engages the kill switch at 1.25x. |

## AI

- No key: strategies + heuristic agents run fully; copilot answers from the
  context ledger without an LLM; the LLM strategist stays silent.
- With `ANTHROPIC_API_KEY` (env or `~/.cortex/secrets.toml`): the strategist
  reviews the context ledger every 5 minutes (configurable) and the copilot
  answers with full market context. Local-first: if `ai.local_llm_url` points
  at an Ollama-compatible server it is tried before Anthropic.
- The LLM can: write thoughts, tighten caution, and vote a signal into fusion.
  It cannot place orders, loosen risk, or touch the kill switch. Ever.

## Diagnostics

- `RUST_LOG=cx_md=debug` — feed tracing. `cx_server=debug` — client traffic.
- Engine unreachable from app: check `lsof -i :9601`, then port config.
- All-agent silence usually means the bus stalled on a panicked task — the
  log will show which squadron; restart the daemon.
