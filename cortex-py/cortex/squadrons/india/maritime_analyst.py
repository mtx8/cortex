"""MaritimeAnalyst — INDIA squadron physical-alpha engine.

Turns live AIS vessel snapshots into leading trading signals:
  - FLOATING-STORAGE INDEX: laden crude tankers drifting (<0.5 kn) and idle >7 days
    outside ports. Rising index = bearish crude / bullish VLCC day-rates. Requires
    *time*, so the analyst tracks per-MMSI idle duration across polls.
  - CHOKEPOINT CONGESTION: vessels geofenced into the world's oil chokepoints
    (Hormuz/Malacca/Suez/...). A queue forming = supply-disruption premium into crude.

Heavy math is in the Rust core (cortex_scanner). These signals front-run EIA/API
inventory prints by 1-7 days; they feed the strategic cycle and are gated by ECHO
risk + the autonomy dial — never naked execution (CLAUDE.md rules #4, #5, #6).
"""

import time
import structlog
from collections import deque

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()

try:
    import cortex_scanner as _cs  # type: ignore
except ImportError:  # pragma: no cover
    _cs = None

# Tunables.
_IDLE_SPEED_KN = 0.5            # below this a vessel is "stationary"
_FLOATING_STORAGE_ALERT = 50.0  # index_score that flips the crude bias
_CONGESTION_ALERT = 45.0        # chokepoint congestion_score worth emitting

# Physical-alpha → ticker maps. Leading bias only; ECHO/autonomy gate execution.
_FLOATING_STORAGE_TICKERS = [
    {"symbol": "CL", "direction": "short", "rationale": "rising crude floating storage"},
    {"symbol": "BNO", "direction": "short", "rationale": "rising crude floating storage"},
    {"symbol": "FRO", "direction": "long", "rationale": "tanker day-rates firm on storage demand"},
    {"symbol": "STNG", "direction": "long", "rationale": "product-tanker rates firm"},
    {"symbol": "DHT", "direction": "long", "rationale": "VLCC rates firm on storage demand"},
]
_CONGESTION_TICKERS = [
    {"symbol": "CL", "direction": "long", "rationale": "chokepoint congestion = supply premium"},
    {"symbol": "BNO", "direction": "long", "rationale": "Brent premium on transit risk"},
    {"symbol": "XLE", "direction": "long", "rationale": "energy equities on supply premium"},
]


class MaritimeAnalyst(BaseAgent):
    """Computes floating-storage + chokepoint-congestion physical alpha from AIS."""

    agent_id = "maritime_analyst"
    squadron = "india"
    subscriptions = [SignalTypes.GEO_VESSEL_BATCH]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._idle_since: dict[int, float] = {}   # mmsi -> first-seen-idle ts
        self._recent: deque[dict] = deque(maxlen=200)
        self._batches = 0
        self._last_floating_storage: dict | None = None
        self._last_congestion: list[dict] = []

    def _update_idle(self, mmsi: int, speed: float, now: float) -> float:
        """Track how long a vessel has been stationary. Returns hours idle."""
        if speed < _IDLE_SPEED_KN:
            first = self._idle_since.setdefault(mmsi, now)
            return max(0.0, (now - first) / 3600.0)
        self._idle_since.pop(mmsi, None)
        return 0.0

    async def handle_signal(self, signal: Signal) -> None:
        if _cs is None:
            return
        vessels = signal.payload.get("vessels", [])
        if not vessels:
            return
        now = time.time()
        self._batches += 1

        # ── Floating storage (tankers only, needs idle duration) ──────────────
        t_speeds, t_hours, t_laden = [], [], []
        for v in vessels:
            if not v.get("is_tanker"):
                continue
            speed = float(v.get("speed_knots", 0.0))
            hours = self._update_idle(int(v.get("mmsi", 0)), speed, now)
            t_speeds.append(speed)
            t_hours.append(hours)
            # Laden proxy: Digitraffic locations omit draught; treat idle tankers as
            # candidate storage. Real laden/ballast comes from vessel metadata (P5).
            draught = float(v.get("draught", 0.0))
            t_laden.append(draught == 0.0 or draught >= 8.0)

        if t_speeds:
            fs = _cs.floating_storage_index(t_speeds, t_hours, t_laden)
            self._last_floating_storage = fs
            await self.emit(SignalTypes.GEO_FLOATING_STORAGE, payload=fs,
                            priority=SignalPriority.LOW)
            if fs["index_score"] >= _FLOATING_STORAGE_ALERT:
                await self._emit_alpha("floating_storage", _FLOATING_STORAGE_TICKERS,
                                       fs["index_score"], extra={"floating_storage": fs})

        # ── Chokepoint congestion (all vessels) ───────────────────────────────
        lats = [float(v.get("lat", 0.0)) for v in vessels]
        lons = [float(v.get("lon", 0.0)) for v in vessels]
        speeds = [float(v.get("speed_knots", 0.0)) for v in vessels]
        types = [int(v.get("ship_type", 0)) for v in vessels]
        congestion = _cs.chokepoint_congestion(lats, lons, speeds, types)
        self._last_congestion = congestion
        for c in congestion:
            if c["congestion_score"] >= _CONGESTION_ALERT:
                await self.emit(SignalTypes.GEO_CHOKEPOINT_CONGESTION, payload=c,
                                priority=SignalPriority.NORMAL)
                await self._emit_alpha("chokepoint_congestion", _CONGESTION_TICKERS,
                                       c["congestion_score"],
                                       extra={"chokepoint": c["name"], "detail": c})

    async def _emit_alpha(self, kind: str, tickers: list[dict], score: float,
                          extra: dict | None = None) -> None:
        confidence = round(min(1.0, score / 100.0), 3)
        payload = {
            "signal": kind,
            "score": score,
            "confidence": confidence,
            "tickers": [{**t, "confidence": confidence} for t in tickers],
            "source": "maritime_ais",
            "ts": time.time(),
        }
        if extra:
            payload.update(extra)
        self._recent.append(payload)
        log.info("maritime.physical_alpha", kind=kind, score=round(score, 1),
                 tickers=[t["symbol"] for t in tickers])
        await self.emit(SignalTypes.GEO_PHYSICAL_ALPHA, payload=payload,
                        priority=SignalPriority.NORMAL)

    def get_recent(self, count: int) -> list[dict]:
        return list(self._recent)[-count:]

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "batches": self._batches,
            "tracked_idle_vessels": len(self._idle_since),
            "last_floating_storage": self._last_floating_storage,
            "congested_chokepoints": len(self._last_congestion),
            "rust_core": _cs is not None,
        })
        return base
