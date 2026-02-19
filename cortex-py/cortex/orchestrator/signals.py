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

    # System
    AGENT_HEALTH = "system.agent_health"
    STRATEGY_UPDATE = "intelligence.strategy_update"
