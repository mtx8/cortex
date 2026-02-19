-- CORTEX PostgreSQL Schema

CREATE TABLE IF NOT EXISTS orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    agent_id        TEXT NOT NULL,
    broker          TEXT NOT NULL CHECK (broker IN ('ibkr', 'coinbase')),
    symbol          TEXT NOT NULL,
    order_type      TEXT NOT NULL CHECK (order_type IN ('market','limit','stop','stop_limit')),
    side            TEXT NOT NULL CHECK (side IN ('buy','sell')),
    quantity        NUMERIC(18, 8) NOT NULL,
    limit_price     NUMERIC(18, 8),
    stop_price      NUMERIC(18, 8),
    broker_order_id TEXT UNIQUE,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','submitted','partial','filled','cancelled','rejected')),
    submitted_at    TIMESTAMPTZ,
    filled_at       TIMESTAMPTZ,
    fill_price      NUMERIC(18, 8),
    fill_quantity   NUMERIC(18, 8),
    commission      NUMERIC(18, 8)
);

CREATE TABLE IF NOT EXISTS trades (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    open_order_id   UUID REFERENCES orders(id),
    close_order_id  UUID REFERENCES orders(id),
    symbol          TEXT NOT NULL,
    quantity        NUMERIC(18, 8) NOT NULL,
    open_price      NUMERIC(18, 8) NOT NULL,
    close_price     NUMERIC(18, 8) NOT NULL,
    open_at         TIMESTAMPTZ NOT NULL,
    close_at        TIMESTAMPTZ NOT NULL,
    realized_pnl    NUMERIC(18, 8) NOT NULL,
    commissions     NUMERIC(18, 8) NOT NULL DEFAULT 0,
    net_pnl         NUMERIC(18, 8) GENERATED ALWAYS AS (realized_pnl - commissions) STORED,
    agent_id        TEXT NOT NULL,
    strategy_tag    TEXT
);

CREATE TABLE IF NOT EXISTS audit_trail (
    id              BIGSERIAL PRIMARY KEY,
    event_id        UUID NOT NULL UNIQUE,
    ts              TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type      TEXT NOT NULL,
    source_agent    TEXT NOT NULL,
    source_squadron TEXT NOT NULL,
    triggered_by_event_id UUID,
    signal_payload  JSONB,
    trade_id        UUID
);

CREATE TABLE IF NOT EXISTS tax_lots (
    lot_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    asset_class     TEXT NOT NULL,
    exchange        TEXT NOT NULL,
    quantity        NUMERIC(18, 8) NOT NULL,
    remaining_qty   NUMERIC(18, 8) NOT NULL,
    cost_basis_per_unit NUMERIC(18, 8) NOT NULL,
    acquisition_date TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'partial')),
    wash_sale_adj   NUMERIC(18, 8) DEFAULT 0,
    agent_id        TEXT
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_orders_symbol ON orders (symbol, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_agent ON orders (agent_id, status);
CREATE INDEX IF NOT EXISTS idx_trades_agent ON trades (agent_id, close_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_trail (ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_type ON audit_trail (event_type, ts DESC);
CREATE INDEX IF NOT EXISTS idx_tax_lots_symbol ON tax_lots (symbol, status);
