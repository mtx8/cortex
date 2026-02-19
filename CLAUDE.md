# CORTEX Architecture Rules

## Enforced Patterns
1. ALL secrets in ~/.cortex/secrets.toml or environment variables. Never hardcode keys.
2. ALL inter-squadron communication via SignalBus. Agents NEVER import from other squadrons.
3. ALL Python async code uses asyncio + uvloop.
4. ALL IBKR API calls go through rate_limiter.py wrappers.
5. ALL agents inherit BaseAgent and implement handle_signal().
6. ALL orders go through TradePipeline -> PreTradeCheck. No bypassing.
7. Claude NEVER in execution hot path. Strategic cycle only.
8. Kill switch Phase 1 is synchronous in-memory. No network dependency.
9. Position reconciliation on every IBKR reconnect.

## Package Decisions (do not change)
- HTTP: httpx | IBKR: ib_async | Coinbase: coinbase-advanced-py
- Redis: redis[hiredis] | Postgres: asyncpg | JSON: orjson
- Validation: pydantic v2 | Config: pydantic-settings
- Rate limiting: aiolimiter | Logging: structlog
