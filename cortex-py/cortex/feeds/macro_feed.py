"""Macro / fixed-income feed — Treasury rate structure on the SignalBus.

Polls Treasury average interest rates (keyless) through the hardened egress,
broadcasts a MACRO_RATES message to Swift, and publishes a juliett.macro_rates
signal the JULIETT squadron analyzes (rate level, short-vs-long spread / inversion).
Closes part of the fixed-income Bloomberg gap with real live data. Degrades
gracefully when the Rust core is absent.
"""

import asyncio
import structlog

from cortex.api.protocol import MessageType, CortexMessage
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.connectors.macro.client import MacroEgressClient
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes

log = structlog.get_logger()


class MacroFeed:
    def __init__(
        self,
        macro_client: MacroEgressClient,
        broadcaster: WSBroadcaster,
        bus: SignalBus,
        poll_interval: float = 3600.0,
        enabled: bool = True,
    ):
        self._macro = macro_client
        self._broadcaster = broadcaster
        self._bus = bus
        self._poll_interval = poll_interval
        self._enabled = enabled
        self._running = False
        self._poll_count = 0
        self._last_rates: dict = {}

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def last_rates(self) -> dict:
        return dict(self._last_rates)

    async def _poll_once(self) -> None:
        try:
            rates = await self._macro.fetch_treasury_rates()
        except Exception as e:
            log.warning("macro_feed.error", error=str(e))
            rates = {}
        if not rates:
            return
        self._last_rates = rates
        self._poll_count += 1

        await self._broadcaster.broadcast(CortexMessage(
            type=MessageType.MACRO_RATES, payload=rates,
        ))
        await self._bus.publish(Signal(
            signal_id=f"macro_rates_{self._poll_count}",
            source_agent="macro_feed",
            source_squadron="feeds",
            signal_type=SignalTypes.MACRO_RATES,
            payload=rates,
            priority=SignalPriority.LOW,
        ))
        log.debug("macro_feed.poll", date=rates.get("date"), spread_bps=rates.get("spread_bps"))

    async def start(self) -> None:
        if not self._enabled:
            log.info("macro_feed.disabled")
            return
        if not self._macro.available:
            log.warning("macro_feed.rust_core_missing")
            return
        self._running = True
        log.info("macro_feed.starting", interval=self._poll_interval)
        while self._running:
            await self._poll_once()
            try:
                await asyncio.sleep(self._poll_interval)
            except asyncio.CancelledError:
                break
        log.info("macro_feed.stopped", polls=self._poll_count)

    async def stop(self) -> None:
        self._running = False

    def to_dict(self) -> dict:
        return {
            "running": self._running,
            "enabled": self._enabled,
            "poll_count": self._poll_count,
            "last_rates": self._last_rates,
        }
