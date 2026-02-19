"""CHARLIE Options Flow Intelligence — unusual options activity detection.

Detects sweeps, block trades, unusual volume, repeated accumulation,
and classifies sentiment from real-time options flow data.  The heavy
lifting lives in the pure-computation :class:`FlowDetector`; the thin
:class:`FlowIntelligence` agent wraps it for the SignalBus.
"""

from __future__ import annotations

import time
import uuid
from collections import defaultdict
from dataclasses import dataclass, field
from enum import Enum

from cortex.orchestrator.bus import Signal, SignalBus
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent


# ---------------------------------------------------------------------------
# Enums & data classes
# ---------------------------------------------------------------------------

class FlowType(Enum):
    SWEEP = "sweep"
    BLOCK = "block"
    UNUSUAL_SIZE = "unusual_size"
    REPEATED = "repeated"
    OPENING = "opening"


@dataclass
class OptionsFlow:
    flow_id: str
    symbol: str
    option_type: str          # "call" / "put"
    strike: float
    expiry: str               # e.g. "2026-03-20"
    premium: float            # total premium paid
    volume: int
    open_interest: int
    side: str                 # "buy" / "sell"
    flow_type: FlowType
    timestamp: float
    is_sweep: bool = False    # multi-exchange sweep
    exchange_count: int = 1


@dataclass
class FlowAlert:
    alert_id: str
    symbol: str
    alert_type: str           # e.g. "bullish_sweep", "bearish_block", "unusual_volume"
    confidence: float         # 0-1
    flows: list[OptionsFlow]
    total_premium: float
    sentiment: str            # "bullish" / "bearish" / "neutral"
    message: str
    timestamp: float = field(default_factory=time.time)


# ---------------------------------------------------------------------------
# FlowDetector — pure computation, no I/O, no bus
# ---------------------------------------------------------------------------

class FlowDetector:
    """Stateless detector for unusual options activity patterns."""

    def __init__(
        self,
        volume_threshold: float = 3.0,
        premium_threshold: float = 100_000.0,
        sweep_exchange_threshold: int = 3,
    ) -> None:
        self._volume_threshold = volume_threshold
        self._premium_threshold = premium_threshold
        self._sweep_exchange_threshold = sweep_exchange_threshold

    # -- Single-flow detection ----------------------------------------------

    def detect_unusual(
        self,
        flow: OptionsFlow,
        avg_volume: float,
    ) -> FlowAlert | None:
        """Return an alert if *flow* has unusual volume or premium."""
        volume_ratio = flow.volume / avg_volume if avg_volume > 0 else 0.0
        high_volume = volume_ratio >= self._volume_threshold
        high_premium = flow.premium >= self._premium_threshold

        if not (high_volume or high_premium):
            return None

        sentiment = "bullish" if flow.option_type == "call" else "bearish"
        confidence = self._compute_confidence(flow, avg_volume)

        parts: list[str] = []
        if high_volume:
            parts.append(f"volume {flow.volume} is {volume_ratio:.1f}x average")
        if high_premium:
            parts.append(f"premium ${flow.premium:,.0f}")

        alert_type = "unusual_volume"
        if high_premium and not high_volume:
            alert_type = "unusual_premium"

        return FlowAlert(
            alert_id=str(uuid.uuid4()),
            symbol=flow.symbol,
            alert_type=alert_type,
            confidence=confidence,
            flows=[flow],
            total_premium=flow.premium,
            sentiment=sentiment,
            message=f"Unusual {flow.option_type} activity on {flow.symbol}: {'; '.join(parts)}",
        )

    # -- Sweep detection (multi-exchange) -----------------------------------

    def detect_sweep(self, flows: list[OptionsFlow]) -> list[FlowAlert]:
        """Group flows by symbol+strike+expiry and flag sweeps."""
        groups: dict[tuple[str, float, str], list[OptionsFlow]] = defaultdict(list)
        for f in flows:
            groups[(f.symbol, f.strike, f.expiry)].append(f)

        alerts: list[FlowAlert] = []
        for key, group in groups.items():
            total_exchanges = sum(f.exchange_count for f in group)
            if total_exchanges < self._sweep_exchange_threshold:
                continue

            total_premium = sum(f.premium for f in group)
            sentiment = self.classify_sentiment(group)

            sentiment_label = "bullish" if sentiment == "bullish" else "bearish"
            alert_type = f"{sentiment_label}_sweep"

            alerts.append(FlowAlert(
                alert_id=str(uuid.uuid4()),
                symbol=key[0],
                alert_type=alert_type,
                confidence=min(1.0, total_exchanges / (self._sweep_exchange_threshold * 2)),
                flows=list(group),
                total_premium=total_premium,
                sentiment=sentiment,
                message=(
                    f"Sweep detected on {key[0]} {key[1]} {key[2]}: "
                    f"{total_exchanges} exchanges, ${total_premium:,.0f} premium"
                ),
            ))

        return alerts

    # -- Accumulation detection ---------------------------------------------

    def detect_accumulation(
        self,
        flows: list[OptionsFlow],
        window_minutes: float = 30.0,
    ) -> list[FlowAlert]:
        """Detect repeated orders in the same contract within *window_minutes*."""
        window_seconds = window_minutes * 60.0
        groups: dict[tuple[str, float, str, str], list[OptionsFlow]] = defaultdict(list)

        for f in flows:
            groups[(f.symbol, f.strike, f.expiry, f.option_type)].append(f)

        alerts: list[FlowAlert] = []
        for key, group in groups.items():
            if len(group) < 2:
                continue

            group.sort(key=lambda f: f.timestamp)

            # Sliding window: count orders within window of the first order
            window_flows: list[OptionsFlow] = []
            for f in group:
                # Remove flows outside the window relative to current flow
                window_flows = [
                    wf for wf in window_flows
                    if (f.timestamp - wf.timestamp) <= window_seconds
                ]
                window_flows.append(f)

                if len(window_flows) >= 3:
                    total_premium = sum(wf.premium for wf in window_flows)
                    sentiment = self.classify_sentiment(window_flows)

                    alerts.append(FlowAlert(
                        alert_id=str(uuid.uuid4()),
                        symbol=key[0],
                        alert_type="accumulation",
                        confidence=min(1.0, len(window_flows) / 10.0),
                        flows=list(window_flows),
                        total_premium=total_premium,
                        sentiment=sentiment,
                        message=(
                            f"Accumulation detected on {key[0]} {key[1]} {key[2]} {key[3]}: "
                            f"{len(window_flows)} orders in {window_minutes:.0f} min, "
                            f"${total_premium:,.0f} premium"
                        ),
                    ))
                    # Only fire once per cluster: reset the window
                    window_flows = []

        return alerts

    # -- Sentiment classification -------------------------------------------

    def classify_sentiment(self, flows: list[OptionsFlow]) -> str:
        """Bullish if call premium > put premium, bearish otherwise."""
        call_premium = sum(f.premium for f in flows if f.option_type == "call")
        put_premium = sum(f.premium for f in flows if f.option_type == "put")

        if call_premium > put_premium:
            return "bullish"
        if put_premium > call_premium:
            return "bearish"
        return "neutral"

    # -- Confidence scoring -------------------------------------------------

    def _compute_confidence(
        self,
        flow: OptionsFlow,
        avg_volume: float,
    ) -> float:
        """Confidence based on volume ratio and premium size.

        Both components are capped at 0.5 so the total is in [0, 1].
        """
        # Volume component: 0 to 0.5
        volume_ratio = flow.volume / avg_volume if avg_volume > 0 else 0.0
        volume_score = min(0.5, (volume_ratio / self._volume_threshold) * 0.25)

        # Premium component: 0 to 0.5
        premium_ratio = flow.premium / self._premium_threshold if self._premium_threshold > 0 else 0.0
        premium_score = min(0.5, premium_ratio * 0.25)

        return min(1.0, volume_score + premium_score)


# ---------------------------------------------------------------------------
# FlowIntelligence — BaseAgent wrapper
# ---------------------------------------------------------------------------

class FlowIntelligence(BaseAgent):
    """Feed-driven agent that detects unusual options activity and emits
    :data:`SignalTypes.SWEEP_DETECTED` alerts on the bus.
    """

    agent_id: str = "flow_intelligence"
    squadron: str = "charlie"
    subscriptions: list[str] = []  # feed-driven, not signal-driven

    def __init__(self, bus: SignalBus) -> None:
        super().__init__(bus)
        self.detector = FlowDetector()
        self._recent_flows: list[OptionsFlow] = []
        self._alerts: list[FlowAlert] = []

    # -- Feed ingestion -----------------------------------------------------

    async def ingest(self, flow: OptionsFlow, avg_volume: float = 0.0) -> None:
        """Ingest a single flow, run detection, and emit alerts."""
        self._recent_flows.append(flow)

        # 1. Single-flow unusual detection
        alert = self.detector.detect_unusual(flow, avg_volume)
        if alert is not None:
            self._alerts.append(alert)
            await self._emit_alert(alert)

        # 2. Sweep detection across recent flows for same contract
        sweep_alerts = self.detector.detect_sweep(self._recent_flows)
        for sa in sweep_alerts:
            if not self._is_duplicate_alert(sa):
                self._alerts.append(sa)
                await self._emit_alert(sa)

        # 3. Accumulation detection
        accum_alerts = self.detector.detect_accumulation(self._recent_flows)
        for aa in accum_alerts:
            if not self._is_duplicate_alert(aa):
                self._alerts.append(aa)
                await self._emit_alert(aa)

    # -- Query API ----------------------------------------------------------

    def get_recent_alerts(self, count: int = 20) -> list[FlowAlert]:
        """Return the most recent *count* alerts, newest first."""
        return sorted(
            self._alerts,
            key=lambda a: a.timestamp,
            reverse=True,
        )[:count]

    def get_alerts_by_symbol(self, symbol: str) -> list[FlowAlert]:
        """Return all alerts for *symbol*, newest first."""
        return sorted(
            [a for a in self._alerts if a.symbol == symbol],
            key=lambda a: a.timestamp,
            reverse=True,
        )

    # -- BaseAgent contract -------------------------------------------------

    async def handle_signal(self, signal: Signal) -> None:
        """No-op — this agent is feed-driven, not signal-driven."""

    # -- Internals ----------------------------------------------------------

    async def _emit_alert(self, alert: FlowAlert) -> None:
        await self.emit(
            SignalTypes.SWEEP_DETECTED,
            payload={
                "alert_id": alert.alert_id,
                "symbol": alert.symbol,
                "alert_type": alert.alert_type,
                "confidence": alert.confidence,
                "total_premium": alert.total_premium,
                "sentiment": alert.sentiment,
                "message": alert.message,
                "flow_count": len(alert.flows),
            },
        )

    def _is_duplicate_alert(self, alert: FlowAlert) -> bool:
        """Avoid emitting near-identical alerts for the same symbol+type."""
        for existing in self._alerts:
            if (
                existing.symbol == alert.symbol
                and existing.alert_type == alert.alert_type
                and set(f.flow_id for f in existing.flows) == set(f.flow_id for f in alert.flows)
            ):
                return True
        return False
