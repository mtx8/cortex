"""GeoRiskMapper — INDIA squadron seismic-to-asset risk agent.

Subscribes to significant earthquakes (ingested by the geo feed) and flags those
near major energy infrastructure (refineries, LNG terminals, export hubs). A strong
quake within range of a hub is a supply-disruption / facility-risk signal that maps
to the affected names and to crude. Distance is computed in the Rust core.

Auto-actions stay behind ECHO risk + the autonomy dial.
"""

import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()

try:
    import cortex_scanner as _cs  # type: ignore
except ImportError:  # pragma: no cover
    _cs = None

# Major energy assets: (name, lat, lon, alert_radius_km, tickers).
_ENERGY_ASSETS: list[dict] = [
    {"name": "US Gulf Coast refining (Houston/Port Arthur)", "lat": 29.76, "lon": -95.36,
     "radius_km": 150.0, "tickers": ["XOM", "VLO", "MPC", "CL"]},
    {"name": "LOOP / Louisiana export", "lat": 28.88, "lon": -90.02,
     "radius_km": 120.0, "tickers": ["CL", "XLE"]},
    {"name": "Cushing OK hub", "lat": 35.98, "lon": -96.77,
     "radius_km": 120.0, "tickers": ["CL", "USO"]},
    {"name": "Ras Tanura (Saudi)", "lat": 26.64, "lon": 50.16,
     "radius_km": 150.0, "tickers": ["CL", "BNO"]},
    {"name": "Ras Laffan LNG (Qatar)", "lat": 25.90, "lon": 51.55,
     "radius_km": 120.0, "tickers": ["LNG", "BNO"]},
    {"name": "Sakhalin / NE Asia LNG", "lat": 53.0, "lon": 142.0,
     "radius_km": 250.0, "tickers": ["LNG", "BNO"]},
]

_MIN_MAG = 5.0  # only meaningful quakes


class GeoRiskMapper(BaseAgent):
    """Flags earthquakes near energy infrastructure as supply-risk signals."""

    agent_id = "geo_risk_mapper"
    squadron = "india"
    subscriptions = [SignalTypes.GEO_SEISMIC]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._alerts = 0

    async def handle_signal(self, signal: Signal) -> None:
        if _cs is None:
            return
        ev = signal.payload
        mag = float(ev.get("magnitude", 0.0))
        if mag < _MIN_MAG:
            return
        lat, lon = float(ev.get("lat", 0.0)), float(ev.get("lon", 0.0))

        for asset in _ENERGY_ASSETS:
            dist = _cs.haversine_km(lat, lon, asset["lat"], asset["lon"])
            if dist <= asset["radius_km"]:
                self._alerts += 1
                # Severity scales with magnitude and closeness.
                proximity = 1.0 - (dist / asset["radius_km"])
                severity = round(min(1.0, (mag - 4.0) / 4.0) * (0.5 + 0.5 * proximity), 3)
                payload = {
                    "signal": "seismic_proximity",
                    "asset": asset["name"],
                    "magnitude": mag,
                    "distance_km": round(dist, 1),
                    "severity": severity,
                    "place": ev.get("label", ""),
                    "tickers": [{"symbol": s, "direction": "long", "rationale":
                                 f"seismic risk to {asset['name']}"} for s in asset["tickers"]],
                    "source": "usgs",
                    "ts": time.time(),
                }
                log.info("geo_risk.seismic_proximity", asset=asset["name"],
                         mag=mag, distance_km=round(dist, 1), severity=severity)
                await self.emit(SignalTypes.GEO_SEISMIC_PROXIMITY, payload=payload,
                                priority=SignalPriority.NORMAL)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({"alerts": self._alerts, "assets_watched": len(_ENERGY_ASSETS),
                     "rust_core": _cs is not None})
        return base
