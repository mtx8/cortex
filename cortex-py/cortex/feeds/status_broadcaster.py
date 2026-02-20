"""Periodic status broadcaster -- pushes portfolio, agent, and opportunity status to Swift clients."""

import asyncio
import structlog
from cortex.api.protocol import MessageType, CortexMessage
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.orchestrator.bus import SignalBus, Signal
from cortex.orchestrator.system import SystemOrchestrator

log = structlog.get_logger()


class StatusBroadcaster:
    """Periodically broadcasts system status to WebSocket clients."""

    def __init__(
        self,
        broadcaster: WSBroadcaster,
        orchestrator: SystemOrchestrator,
        bus: SignalBus | None = None,
        drawdown_shield=None,
        interval: float = 5.0,
    ):
        self._broadcaster = broadcaster
        self._orchestrator = orchestrator
        self._bus = bus
        self._drawdown_shield = drawdown_shield
        self._interval = interval
        self._running = False
        self._portfolio_state = {
            "nav": 0.0,
            "daily_pnl": 0.0,
            "total_pnl": 0.0,
            "win_rate": 0.0,
            "buying_power": 0.0,
            "open_positions": 0,
            "sharpe_ratio": 0.0,
        }

        # Subscribe to portfolio-related signals on the bus
        if self._bus is not None:
            self._bus.subscribe("bravo.order_filled", self.handle_portfolio_signal)
            self._bus.subscribe("bravo.order_submitted", self.handle_portfolio_signal)

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def interval(self) -> float:
        return self._interval

    @property
    def portfolio_state(self) -> dict:
        return dict(self._portfolio_state)

    def update_portfolio(self, **kwargs) -> None:
        """Update portfolio state (called by connectors when real data arrives)."""
        self._portfolio_state.update(kwargs)

    async def handle_portfolio_signal(self, signal: Signal) -> None:
        """Update portfolio state from bus signals."""
        payload = signal.payload
        if signal.signal_type == "bravo.order_filled":
            # Update position count on order fill
            self._portfolio_state["open_positions"] = self._portfolio_state.get("open_positions", 0) + 1
        elif signal.signal_type == "bravo.order_submitted":
            # Track submitted orders for activity
            pass

    async def start(self) -> None:
        """Start periodic broadcasting loop."""
        self._running = True
        log.info("status_broadcaster.started", interval=self._interval)
        while self._running:
            try:
                await self._broadcast_all()
            except Exception as e:
                log.error("status_broadcaster.error", error=str(e))
            await asyncio.sleep(self._interval)

    async def stop(self) -> None:
        self._running = False

    async def _broadcast_all(self) -> None:
        if self._broadcaster.client_count == 0:
            return

        # Update DrawdownShield with current NAV if available
        if self._drawdown_shield and self._portfolio_state.get("nav", 0) > 0:
            self._drawdown_shield.update(self._portfolio_state["nav"])

        # 1. Portfolio update
        await self._broadcaster.broadcast(CortexMessage(
            type=MessageType.PORTFOLIO_UPDATE,
            payload=self._portfolio_state,
        ))

        # 2. Agent updates
        for agent in self._orchestrator.agents:
            await self._broadcaster.broadcast(CortexMessage(
                type=MessageType.AGENT_UPDATE,
                payload={
                    "agent_id": agent.agent_id,
                    "squadron": getattr(agent, "squadron", "unknown"),
                    "status": getattr(agent, "status", "active"),
                    "signal_count": getattr(agent, "signal_count", 0),
                    "error_count": getattr(agent, "error_count", 0),
                },
            ))

        # 3. Activity event -- heartbeat so the Swift activity feed stays alive
        # Use ACTIVITY ("activity") to match the Swift MessageRouter's routing key
        await self._broadcaster.broadcast(CortexMessage(
            type=MessageType.ACTIVITY,
            payload={
                "event_type": "heartbeat",
                "message": "System nominal -- all agents active",
                "severity": "info",
                "symbol": "",
            },
        ))
