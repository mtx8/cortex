"""Prompt templates for Claude strategic intelligence cycle."""


def build_strategic_prompt(
    nav: float,
    daily_pnl: float,
    positions: list[dict],
    recent_signals: list[str],
    drawdown_pct: float,
    win_rate: float,
) -> str:
    positions_text = "\n".join(
        f"  - {p.get('symbol', '?')}: P&L ${p.get('pnl', 0):.2f}"
        for p in positions
    ) or "  (no open positions)"

    signals_text = "\n".join(f"  - {s}" for s in recent_signals[-20:]) or "  (none)"

    return f"""You are the strategic intelligence core of CORTEX, an autonomous trading system.
Analyze the current portfolio state and market conditions, then output a JSON strategy decision.

## Current Portfolio State
- NAV: ${nav:,.2f}
- Daily P&L: ${daily_pnl:,.2f}
- Current Drawdown: {drawdown_pct:.1f}%
- Win Rate: {win_rate:.1%}
- Open Positions:
{positions_text}

## Recent Signals (last 20)
{signals_text}

## Your Task
Output a JSON object with exactly these fields:
{{
  "market_regime": "bullish" | "bearish" | "neutral" | "volatile",
  "sector_focus": ["sector1", "sector2"],
  "risk_appetite": 0.0 to 1.0,
  "signals_to_amplify": ["signal.type.to.boost"],
  "signals_to_suppress": ["signal.type.to.ignore"],
  "reasoning": "1-2 sentence explanation"
}}

Respond ONLY with the JSON object, no markdown fences or explanation."""


def build_risk_assessment_prompt(
    symbol: str,
    entry_price: float,
    position_size: int,
    portfolio_nav: float,
    current_drawdown: float,
) -> str:
    notional = entry_price * position_size
    pct_of_nav = (notional / portfolio_nav * 100) if portfolio_nav > 0 else 0

    return f"""Assess the risk of this proposed trade:

- Symbol: {symbol}
- Entry Price: ${entry_price:.2f}
- Position Size: {position_size} shares
- Notional: ${notional:,.2f} ({pct_of_nav:.1f}% of NAV)
- Current Drawdown: {current_drawdown:.1f}%
- Portfolio NAV: ${portfolio_nav:,.2f}

Output JSON:
{{
  "approve": true | false,
  "confidence": 0.0 to 1.0,
  "reasoning": "explanation"
}}

Respond ONLY with the JSON object."""
