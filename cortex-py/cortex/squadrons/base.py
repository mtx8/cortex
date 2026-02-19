"""Base class for all CORTEX agents. All 44 agents inherit from this."""

from abc import ABC, abstractmethod
import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal

log = structlog.get_logger()


class BaseAgent(ABC):
    agent_id: str = "unset"
    squadron: str = "unset"
    subscriptions: list[str] = []

    def __init__(self, bus: SignalBus):
        self._bus = bus
        self._status = "idle"
        self._signal_count = 0
        self._last_signal_ts: float | None = None
        self._error_count = 0

    @property
    def status(self) -> str:
        return self._status

    @property
    def signal_count(self) -> int:
        return self._signal_count

    @property
    def error_count(self) -> int:
        return self._error_count

    def register(self) -> None:
        for signal_type in self.subscriptions:
            self._bus.subscribe(signal_type, self._on_signal)
        self._status = "active"
        log.info("agent.registered", agent_id=self.agent_id, squadron=self.squadron)

    async def _on_signal(self, signal: Signal) -> None:
        self._signal_count += 1
        self._last_signal_ts = time.time()
        try:
            await self.handle_signal(signal)
        except Exception as e:
            self._error_count += 1
            log.error(
                "agent.handle_error",
                agent_id=self.agent_id,
                error=str(e),
                signal_type=signal.signal_type,
            )

    @abstractmethod
    async def handle_signal(self, signal: Signal) -> None:
        ...

    async def emit(self, signal_type: str, payload: dict, priority=None) -> None:
        from cortex.orchestrator.bus import SignalPriority
        await self._bus.publish(Signal(
            signal_id=f"{self.agent_id}_{self._signal_count}",
            source_agent=self.agent_id,
            source_squadron=self.squadron,
            signal_type=signal_type,
            payload=payload,
            priority=priority or SignalPriority.NORMAL,
        ))

    def to_dict(self) -> dict:
        return {
            "agent_id": self.agent_id,
            "squadron": self.squadron,
            "status": self._status,
            "signal_count": self._signal_count,
            "error_count": self._error_count,
            "last_signal_ts": self._last_signal_ts,
        }
