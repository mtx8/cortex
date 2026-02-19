"""SignalBus — the central nervous system of CORTEX.
ALL inter-agent communication goes through here. No exceptions.
Squadron agents NEVER import from other squadrons directly."""

import asyncio
import time
from collections import defaultdict
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Awaitable
import structlog

log = structlog.get_logger()


class SignalPriority(IntEnum):
    CRITICAL = 0  # Kill switch, risk breach
    HIGH = 1      # Order execution signals
    NORMAL = 2    # Standard agent signals
    LOW = 3       # Analytics, non-actionable


@dataclass
class Signal:
    signal_id: str
    source_agent: str
    source_squadron: str
    signal_type: str
    payload: dict
    priority: SignalPriority
    timestamp: float = field(default_factory=time.time)
    target_agents: list[str] = field(default_factory=list)

    def __lt__(self, other: "Signal") -> bool:
        return self.priority < other.priority


class SignalBus:
    def __init__(self):
        self._queue: asyncio.PriorityQueue[tuple[int, float, Signal]] = (
            asyncio.PriorityQueue()
        )
        self._subscribers: dict[str, list[Callable[[Signal], Awaitable[None]]]] = (
            defaultdict(list)
        )
        self._state: dict[str, Signal] = {}
        self._dispatch_count = 0
        self._seq = 0

    async def publish(self, signal: Signal) -> None:
        self._seq += 1
        await self._queue.put((signal.priority.value, self._seq, signal))

    def subscribe(
        self, signal_type: str, handler: Callable[[Signal], Awaitable[None]]
    ) -> None:
        self._subscribers[signal_type].append(handler)

    def subscribe_all(
        self, handler: Callable[[Signal], Awaitable[None]]
    ) -> None:
        self._subscribers["*"].append(handler)

    async def run(self) -> None:
        while True:
            _, _, signal = await self._queue.get()
            self._state[signal.signal_type] = signal
            self._dispatch_count += 1

            handlers = list(self._subscribers.get(signal.signal_type, []))
            handlers += list(self._subscribers.get("*", []))

            if handlers:
                results = await asyncio.gather(
                    *[h(signal) for h in handlers],
                    return_exceptions=True,
                )
                for i, result in enumerate(results):
                    if isinstance(result, Exception):
                        log.error(
                            "bus.handler_error",
                            signal_type=signal.signal_type,
                            error=str(result),
                        )

            self._queue.task_done()

    def get_current_state(self) -> dict[str, Signal]:
        return dict(self._state)

    @property
    def dispatch_count(self) -> int:
        return self._dispatch_count
