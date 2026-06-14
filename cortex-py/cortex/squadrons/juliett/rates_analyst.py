"""RatesAnalyst — JULIETT squadron macro/fixed-income agent.

Turns the Treasury rate structure into regime signals:
  - CURVE INVERSION: short (Bills) yielding more than long (Bonds) — a classic
    recession lead → risk-off tilt (long duration TLT, defensives; trim cyclicals).
  - RATES REGIME: absolute rate level (restrictive vs accommodative) → risk appetite.

A short-vs-long spread from Treasury *average* rates is a proxy for the true daily
par-yield curve (a documented refinement: home.treasury.gov par curve XML). Signals
are leading-indicator context for the strategic cycle, gated by ECHO + autonomy.
"""

import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()

# A clearly restrictive long-rate level (heuristic).
_RESTRICTIVE_PCT = 4.5
_ACCOMMODATIVE_PCT = 2.5


class RatesAnalyst(BaseAgent):
    agent_id = "rates_analyst"
    squadron = "juliett"
    subscriptions = [SignalTypes.MACRO_RATES]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._last_spread_bps: float | None = None
        self._last_regime: str | None = None
        self._inversions = 0

    async def handle_signal(self, signal: Signal) -> None:
        p = signal.payload
        long_pct = p.get("long_pct")

        # PREFER the real par-yield curve (canonical 2s10s / 3m10s) when present;
        # fall back to the average-rate short-vs-long proxy when it's absent.
        par = p.get("par_curve") or {}
        s2s10s = par.get("spread_2s10s_bps")
        s3m10s = par.get("spread_3m10s_bps")
        if s2s10s is not None or s3m10s is not None:
            # Use 2s10s as the headline spread, 3m10s as the secondary trigger.
            spread = s2s10s if s2s10s is not None else s3m10s
            inverted = (s2s10s is not None and s2s10s < 0) or (s3m10s is not None and s3m10s < 0)
            curve_source = "treasury_par_curve"
            curve_date = par.get("date") or p.get("date")
        else:
            spread = p.get("spread_bps")
            inverted = spread is not None and spread < 0
            curve_source = "treasury_avg_rates"
            curve_date = p.get("date")
        self._last_spread_bps = spread

        # Curve inversion (short > long => negative spread).
        if inverted:
            self._inversions += 1
            await self.emit(SignalTypes.YIELD_CURVE_INVERSION, payload={
                "signal": "yield_curve_inversion",
                "spread_bps": spread,
                "spread_2s10s_bps": s2s10s,
                "spread_3m10s_bps": s3m10s,
                "date": curve_date,
                "tickers": [
                    {"symbol": "TLT", "direction": "long", "rationale": "inversion → duration bid / risk-off"},
                    {"symbol": "XLF", "direction": "short", "rationale": "inversion pressures bank NIM / cyclicals"},
                    {"symbol": "XLU", "direction": "long", "rationale": "defensives outperform into slowdown"},
                ],
                "source": curve_source,
                "ts": time.time(),
            }, priority=SignalPriority.NORMAL)
            log.info("rates.inversion", spread_bps=spread, s2s10s=s2s10s,
                     s3m10s=s3m10s, source=curve_source, date=curve_date)

        # Rate-level regime → risk appetite hint for the strategic cycle.
        regime = None
        if long_pct is not None:
            if long_pct >= _RESTRICTIVE_PCT:
                regime = "restrictive"
            elif long_pct <= _ACCOMMODATIVE_PCT:
                regime = "accommodative"
            else:
                regime = "neutral"
        if regime and regime != self._last_regime:
            self._last_regime = regime
            await self.emit(SignalTypes.RATES_REGIME, payload={
                "signal": "rates_regime",
                "regime": regime,
                "long_pct": long_pct,
                "spread_bps": spread,
                "date": p.get("date"),
                "source": "treasury",
                "ts": time.time(),
            }, priority=SignalPriority.LOW)
            log.info("rates.regime", regime=regime, long_pct=long_pct)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "last_spread_bps": self._last_spread_bps,
            "last_regime": self._last_regime,
            "inversions": self._inversions,
        })
        return base
