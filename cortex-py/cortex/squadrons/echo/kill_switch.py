"""Kill Switch Commander — emergency halt of all trading activity.
Phase 1 (halt flag) is synchronous and in-memory only.
No network call can delay it."""

import time
from enum import Enum
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class KillSwitchState(str, Enum):
    ARMED = "armed"           # Normal operation
    ENGAGED = "engaged"       # Halted, no trading
    RECOVERING = "recovering" # Closing positions


class KillSwitchCommander(BaseAgent):
    agent_id = "kill_switch_commander"
    squadron = "echo"
    subscriptions = []  # Doesn't subscribe — it COMMANDS

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._state = KillSwitchState.ARMED
        self._is_halted = False
        self._engaged_at: float | None = None
        self._engaged_reason: str | None = None
        self._engaged_by: str | None = None

    @property
    def state(self) -> KillSwitchState:
        return self._state

    @property
    def is_halted(self) -> bool:
        return self._is_halted

    async def engage(self, reason: str, triggered_by: str) -> None:
        # PHASE 1: Synchronous halt flag — this MUST be instant
        self._is_halted = True
        self._state = KillSwitchState.ENGAGED
        self._engaged_at = time.time()
        self._engaged_reason = reason
        self._engaged_by = triggered_by

        log.critical(
            "KILL_SWITCH_ENGAGED",
            reason=reason,
            triggered_by=triggered_by,
        )

        # Broadcast to all agents via bus
        await self.emit(
            SignalTypes.KILL_SWITCH,
            payload={
                "reason": reason,
                "triggered_by": triggered_by,
                "engaged_at": self._engaged_at,
                "phase": "halt",
            },
            priority=SignalPriority.CRITICAL,
        )

    def disengage(self, operator: str) -> None:
        log.warning("KILL_SWITCH_DISENGAGED", operator=operator)
        self._is_halted = False
        self._state = KillSwitchState.ARMED
        self._engaged_at = None
        self._engaged_reason = None

    async def handle_signal(self, signal: Signal) -> None:
        pass  # Kill switch doesn't react to signals — it commands

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "kill_switch_state": self._state.value,
            "is_halted": self._is_halted,
            "engaged_at": self._engaged_at,
            "engaged_reason": self._engaged_reason,
        })
        return base
