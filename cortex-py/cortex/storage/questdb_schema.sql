-- CORTEX QuestDB Time-Series Schema

CREATE TABLE IF NOT EXISTS quotes (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    bid         DOUBLE,
    ask         DOUBLE,
    bid_size    INT,
    ask_size    INT,
    source      SYMBOL CAPACITY 10 CACHE
) TIMESTAMP(ts) PARTITION BY DAY WAL;

CREATE TABLE IF NOT EXISTS ohlcv (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    open        DOUBLE,
    high        DOUBLE,
    low         DOUBLE,
    close       DOUBLE,
    volume      LONG,
    vwap        DOUBLE,
    timeframe   SYMBOL CAPACITY 10 CACHE
) TIMESTAMP(ts) PARTITION BY MONTH WAL;

CREATE TABLE IF NOT EXISTS options_chain (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    expiry      TIMESTAMP,
    strike      DOUBLE,
    option_type SYMBOL CAPACITY 2 CACHE,
    bid         DOUBLE,
    ask         DOUBLE,
    iv          DOUBLE,
    delta       DOUBLE,
    gamma       DOUBLE,
    theta       DOUBLE,
    vega        DOUBLE,
    open_interest LONG,
    volume      LONG
) TIMESTAMP(ts) PARTITION BY MONTH WAL;
