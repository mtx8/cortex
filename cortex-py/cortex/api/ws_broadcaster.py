"""WebSocket state broadcaster — fans out system state to all connected Swift clients."""

import structlog
from cortex.api.protocol import MessageType, CortexMessage, encode_message
from cortex.orchestrator.bus import SignalBus, Signal

log = structlog.get_logger()


class WSBroadcaster:
    """Broadcasts system state to connected WebSocket clients."""

    def __init__(self, bus: SignalBus):
        self._bus = bus
        self._clients: list = []  # Will hold WebSocket connections

    @property
    def client_count(self) -> int:
        return len(self._clients)

    def add_client(self, ws) -> None:
        self._clients.append(ws)
        log.info("ws.client_connected", total=self.client_count)

    def remove_client(self, ws) -> None:
        if ws in self._clients:
            self._clients.remove(ws)
            log.info("ws.client_disconnected", total=self.client_count)

    async def broadcast(self, msg: CortexMessage) -> None:
        if not self._clients:
            return
        data = encode_message(msg)
        disconnected = []
        for client in self._clients:
            try:
                await client.send_bytes(data)
            except Exception:
                disconnected.append(client)
        for client in disconnected:
            self.remove_client(client)

    def build_portfolio_message(
        self, nav: float, daily_pnl: float, total_pnl: float,
        win_rate: float, open_positions: int,
    ) -> CortexMessage:
        return CortexMessage(
            type=MessageType.PORTFOLIO_UPDATE,
            payload={
                "nav": nav,
                "daily_pnl": daily_pnl,
                "total_pnl": total_pnl,
                "win_rate": win_rate,
                "open_positions": open_positions,
            },
        )

    def build_agent_message(
        self, agent_id: str, squadron: str,
        status: str, signal_count: int, error_count: int,
    ) -> CortexMessage:
        return CortexMessage(
            type=MessageType.AGENT_UPDATE,
            payload={
                "agent_id": agent_id,
                "squadron": squadron,
                "status": status,
                "signal_count": signal_count,
                "error_count": error_count,
            },
        )

    def build_signal_message(
        self, signal_type: str, source_agent: str,
        symbol: str, payload: dict,
    ) -> CortexMessage:
        return CortexMessage(
            type=MessageType.SIGNAL_FIRED,
            payload={
                "signal_type": signal_type,
                "source_agent": source_agent,
                "symbol": symbol,
                **payload,
            },
        )

    def build_kill_switch_message(self, active: bool, reason: str) -> CortexMessage:
        return CortexMessage(
            type=MessageType.KILL_SWITCH_STATUS,
            payload={"active": active, "reason": reason},
        )

    async def handle_bus_signal(self, signal: Signal) -> None:
        """Handler subscribed to bus for broadcasting signals to clients."""
        msg = self.build_signal_message(
            signal_type=signal.signal_type,
            source_agent=signal.source_agent,
            symbol=signal.payload.get("symbol", ""),
            payload=signal.payload,
        )
        await self.broadcast(msg)
