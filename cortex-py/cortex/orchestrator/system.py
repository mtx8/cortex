"""System Orchestrator — manages agent lifecycle, health monitoring, and system state."""

import asyncio
import time
from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.autonomy import AutonomyDial
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


@dataclass
class AgentHealth:
    agent_id: str
    squadron: str
    status: str
    signal_count: int
    error_count: int
    last_signal_ts: float
    updated_at: float = field(default_factory=time.time)

    @property
    def is_healthy(self) -> bool:
        if self.signal_count == 0:
            return True  # No signals yet, assume healthy
        error_rate = self.error_count / max(self.signal_count, 1)
        return error_rate < 0.5


class SystemOrchestrator:
    """Manages all CORTEX agents, their lifecycle, and health monitoring."""

    def __init__(self, bus: SignalBus, autonomy: AutonomyDial):
        self._bus = bus
        self._autonomy = autonomy
        self._agents: dict[str, BaseAgent] = {}
        self._is_running = False
        self._started_at: float | None = None
        self._bus_task: asyncio.Task | None = None

    def register_agent(self, agent: BaseAgent) -> None:
        self._agents[agent.agent_id] = agent
        agent.register()
        log.info("orchestrator.agent_registered", agent_id=agent.agent_id, squadron=agent.squadron)

    @property
    def agents(self) -> list[BaseAgent]:
        """Return all registered agents (used by StatusBroadcaster)."""
        return list(self._agents.values())

    @property
    def agent_count(self) -> int:
        return len(self._agents)

    @property
    def is_running(self) -> bool:
        return self._is_running

    async def start(self) -> None:
        self._is_running = True
        self._started_at = time.time()
        log.info("orchestrator.started", agent_count=self.agent_count)

        # Start the signal bus
        self._bus_task = asyncio.create_task(self._bus.run())
        try:
            await self._bus_task
        except asyncio.CancelledError:
            pass

    async def stop(self) -> None:
        self._is_running = False
        if self._bus_task:
            self._bus_task.cancel()
            try:
                await self._bus_task
            except asyncio.CancelledError:
                pass
        log.info("orchestrator.stopped")

    def get_agent_health(self, agent_id: str) -> AgentHealth | None:
        agent = self._agents.get(agent_id)
        if not agent:
            return None
        d = agent.to_dict()
        return AgentHealth(
            agent_id=d["agent_id"],
            squadron=d["squadron"],
            status=d.get("status", "active"),
            signal_count=d.get("signal_count", 0),
            error_count=d.get("error_count", 0),
            last_signal_ts=d.get("last_signal_ts", 0.0),
        )

    def get_squadron_health(self, squadron: str) -> list[AgentHealth]:
        return [
            self.get_agent_health(aid)
            for aid, agent in self._agents.items()
            if agent.squadron == squadron
            and self.get_agent_health(aid) is not None
        ]

    def to_dict(self) -> dict:
        return {
            "agent_count": self.agent_count,
            "is_running": self._is_running,
            "started_at": self._started_at,
            "autonomy": self._autonomy.to_dict(),
            "agents": [a.to_dict() for a in self._agents.values()],
        }
