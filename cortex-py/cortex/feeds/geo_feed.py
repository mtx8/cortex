"""Geo-intelligence feed — the ingestion half of the physical-alpha pipeline.

Every poll it fetches live maritime AIS (tankers) and seismic events through the
hardened Rust egress, fans the raw observations out to Swift clients (GEO_POSITION
/ GEO_SIGNAL), and publishes them onto the SignalBus:
  - one `india.geo_vessel_batch` signal carrying the full vessel snapshot
    (MaritimeAnalyst computes floating-storage + chokepoint congestion from it), and
  - one `india.geo_seismic` signal per significant earthquake (GeoRiskMapper checks
    proximity to energy assets).

Analysis lives in the INDIA squadron, not here (feeds ingest, squadrons analyze).
Degrades gracefully: if the Rust core is absent or a fetch fails, it logs and keeps
running rather than taking down the app.
"""

import asyncio
import structlog

from cortex.api.protocol import MessageType, CortexMessage
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.connectors.geo.client import GeoEgressClient
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes

log = structlog.get_logger()

# Earthquakes below this magnitude are ignored for trading-risk purposes.
_MIN_SEISMIC_MAG = 4.5


def _vessel_to_dict(v) -> dict:
    return {
        "mmsi": v.mmsi,
        "lat": v.lat,
        "lon": v.lon,
        "speed_knots": v.speed_knots,
        "heading": v.heading,
        "ship_type": v.ship_type,
        "category": v.category,
        "is_tanker": v.is_tanker,
        "name": v.name,
        "draught": v.draught,
        "chokepoint": v.chokepoint,
        "timestamp_ms": v.timestamp_ms,
    }


def _event_to_dict(e) -> dict:
    return {
        "source": e.source,
        "kind": e.kind,
        "id": e.id,
        "lat": e.lat,
        "lon": e.lon,
        "magnitude": e.magnitude,
        "depth_km": e.depth_km,
        "label": e.label,
        "timestamp_ms": e.timestamp_ms,
    }


class GeoIntelligenceFeed:
    """Polls maritime AIS + seismic feeds and fans out to Swift + the bus."""

    def __init__(
        self,
        geo_client: GeoEgressClient,
        broadcaster: WSBroadcaster,
        bus: SignalBus,
        poll_interval: float = 60.0,
        enabled: bool = True,
    ):
        self._geo = geo_client
        self._broadcaster = broadcaster
        self._bus = bus
        self._poll_interval = poll_interval
        self._enabled = enabled
        self._running = False
        self._poll_count = 0
        self._last_vessels: list[dict] = []
        self._last_events: list[dict] = []
        self._warned_unavailable = False

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def poll_count(self) -> int:
        return self._poll_count

    @property
    def last_vessels(self) -> list[dict]:
        return list(self._last_vessels)

    async def _poll_once(self) -> None:
        # Maritime AIS → batch signal + Swift positions.
        try:
            vessels = await self._geo.fetch_ais_vessels()
        except Exception as e:
            log.warning("geo_feed.ais_error", error=str(e))
            vessels = []

        if vessels:
            vdicts = [_vessel_to_dict(v) for v in vessels]
            self._last_vessels = vdicts
            tankers = sum(1 for d in vdicts if d["is_tanker"])

            await self._broadcaster.broadcast(CortexMessage(
                type=MessageType.GEO_POSITION,
                payload={"vessels": vdicts, "count": len(vdicts), "tankers": tankers},
            ))
            await self._bus.publish(Signal(
                signal_id=f"geo_vessel_batch_{self._poll_count}",
                source_agent="geo_feed",
                source_squadron="feeds",
                signal_type=SignalTypes.GEO_VESSEL_BATCH,
                payload={"vessels": vdicts},
                priority=SignalPriority.LOW,
            ))

        # Seismic → per-event signal (significant only) + Swift events.
        try:
            events = await self._geo.fetch_earthquakes("all_hour")
        except Exception as e:
            log.warning("geo_feed.usgs_error", error=str(e))
            events = []

        sig_events = [_event_to_dict(e) for e in events if e.magnitude >= _MIN_SEISMIC_MAG]
        if sig_events:
            self._last_events = sig_events
            await self._broadcaster.broadcast(CortexMessage(
                type=MessageType.GEO_SIGNAL,
                payload={"events": sig_events, "count": len(sig_events)},
            ))
            for ev in sig_events:
                await self._bus.publish(Signal(
                    signal_id=f"geo_seismic_{ev['id']}_{self._poll_count}",
                    source_agent="geo_feed",
                    source_squadron="feeds",
                    signal_type=SignalTypes.GEO_SEISMIC,
                    payload=ev,
                    priority=SignalPriority.NORMAL,
                ))

        self._poll_count += 1
        log.debug("geo_feed.poll", poll=self._poll_count,
                  vessels=len(self._last_vessels), events=len(sig_events))

    async def start(self) -> None:
        """Run the polling loop as an asyncio task."""
        if not self._enabled:
            log.info("geo_feed.disabled")
            return
        if not self._geo.available:
            log.warning("geo_feed.rust_core_missing",
                        hint="build cortex-rs (maturin develop) to enable geo-intelligence")
            return

        self._running = True
        log.info("geo_feed.starting", interval=self._poll_interval,
                 allowed_hosts=len(self._geo.allowed_hosts))
        while self._running:
            await self._poll_once()
            try:
                await asyncio.sleep(self._poll_interval)
            except asyncio.CancelledError:
                break
        log.info("geo_feed.stopped", polls=self._poll_count)

    async def stop(self) -> None:
        self._running = False
        log.info("geo_feed.stop_requested")

    def to_dict(self) -> dict:
        return {
            "running": self._running,
            "enabled": self._enabled,
            "poll_count": self._poll_count,
            "poll_interval": self._poll_interval,
            "tracked_vessels": len(self._last_vessels),
            "geo_core": self._geo.to_dict(),
        }
