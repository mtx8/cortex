"""Complete signal type registry for inter-agent communication."""


class SignalTypes:
    # ALPHA -> everyone
    MARKET_SIGNAL = "alpha.market_signal"
    PATTERN_DETECTED = "alpha.pattern_detected"
    VOLUME_SURGE = "alpha.volume_surge"
    GAP_DETECTED = "alpha.gap_detected"
    SECTOR_ROTATION = "alpha.sector_rotation"
    ENTRY_SIGNAL = "alpha.entry_signal"
    EXIT_SIGNAL = "alpha.exit_signal"

    # CHARLIE -> BRAVO
    OPTIONS_ENTRY = "charlie.options_entry"
    OPTIONS_EXIT = "charlie.options_exit"
    SWEEP_DETECTED = "charlie.sweep_detected"

    # DELTA -> ALPHA, CHARLIE
    NEWS_CATALYST = "delta.news_catalyst"
    CATALYST_DETECTED = "delta.catalyst_detected"
    EARNINGS_ALERT = "delta.earnings_alert"
    INSIDER_SIGNAL = "delta.insider_signal"
    CONGRESS_TRADE = "delta.congress_trade"
    EDGAR_FILING = "delta.edgar_filing"

    # ECHO -> everyone (risk overrides all)
    RISK_BREACH = "echo.risk_breach"
    DRAWDOWN_WARNING = "echo.drawdown_warning"
    KILL_SWITCH = "echo.kill_switch"
    POSITION_SIZE = "echo.position_size"

    # BRAVO -> ECHO, FOXTROT
    ORDER_SUBMITTED = "bravo.order_submitted"
    ORDER_FILLED = "bravo.order_filled"
    ORDER_REJECTED = "bravo.order_rejected"
    SLIPPAGE_REPORT = "bravo.slippage_report"

    # FOXTROT -> BRAVO
    TAX_HARVEST_SIGNAL = "foxtrot.tax_harvest"
    WASH_SALE_BLOCK = "foxtrot.wash_sale_block"

    # GOLF -> everyone (adaptive learning)
    TRADE_RECORDED = "golf.trade_recorded"
    PATTERN_LEARNED = "golf.pattern_learned"
    STRATEGY_OPTIMIZED = "golf.strategy_optimized"
    REGIME_CHANGE = "golf.regime_change"
    PERFORMANCE_UPDATE = "golf.performance_update"
    DRAWDOWN_ANALYSIS = "golf.drawdown_analysis"
    SECTOR_MOMENTUM = "golf.sector_momentum"
    CORRELATION_SHIFT = "golf.correlation_shift"

    # HOTEL -> BRAVO, ALPHA (market microstructure)
    SPREAD_ALERT = "hotel.spread_alert"
    DEPTH_IMBALANCE = "hotel.depth_imbalance"
    TICK_PATTERN = "hotel.tick_pattern"
    PRICE_LEVEL_MAP = "hotel.price_level_map"
    EXECUTION_RECOMMENDATION = "hotel.execution_recommendation"
    LATENCY_ALERT = "hotel.latency_alert"

    # INDIA -> ECHO, GOLF, intelligence (geospatial alt-data / physical alpha)
    GEO_VESSEL_BATCH = "india.geo_vessel_batch"          # feed -> analyst (raw AIS snapshot)
    GEO_VESSEL_POSITION = "india.geo_vessel_position"
    GEO_PHYSICAL_ALPHA = "india.geo_physical_alpha"       # actionable: tanker/supply -> tickers
    GEO_FLOATING_STORAGE = "india.geo_floating_storage"
    GEO_CHOKEPOINT_CONGESTION = "india.geo_chokepoint_congestion"
    GEO_DARK_SHIP = "india.geo_dark_ship"
    GEO_SEISMIC = "india.geo_seismic"                     # feed -> risk mapper
    GEO_SEISMIC_PROXIMITY = "india.geo_seismic_proximity" # quake near an energy asset
    EGRESS_VALIDATION_FAILED = "india.egress_failed"

    # JULIETT -> ECHO, GOLF, intelligence (macro / fixed income)
    MACRO_RATES = "juliett.macro_rates"                   # feed -> rates analyst
    YIELD_CURVE_INVERSION = "juliett.yield_curve_inversion"
    RATES_REGIME = "juliett.rates_regime"

    # System
    AGENT_HEALTH = "system.agent_health"
    STRATEGY_UPDATE = "intelligence.strategy_update"
