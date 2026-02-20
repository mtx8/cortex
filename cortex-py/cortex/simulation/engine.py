"""Simulation engine orchestrating paper trading with AI agents."""

import asyncio
import time

import structlog

from cortex.simulation.paper_portfolio import PaperPortfolio

log = structlog.get_logger()


class SimulationEngine:
    def __init__(self, bus, portfolio: PaperPortfolio | None = None, broadcaster=None):
        self._bus = bus
        self._portfolio = portfolio or PaperPortfolio()
        self._broadcaster = broadcaster
        self._running = False
        self._start_time: float = 0.0
        self._update_task: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self._running

    @property
    def portfolio(self) -> PaperPortfolio:
        return self._portfolio

    async def start(self, starting_capital: float = 100_000.0) -> None:
        if self._running:
            return
        self._portfolio = PaperPortfolio(starting_capital=starting_capital)
        self._running = True
        self._start_time = time.time()
        self._update_task = asyncio.create_task(self._broadcast_loop())
        log.info("simulation.started", capital=starting_capital)

    async def stop(self) -> dict:
        self._running = False
        if self._update_task:
            self._update_task.cancel()
            try:
                await self._update_task
            except asyncio.CancelledError:
                pass
        stats = self.stats
        log.info("simulation.stopped", stats=stats)
        return stats

    async def _broadcast_loop(self) -> None:
        while self._running:
            await self._broadcast_update()
            await asyncio.sleep(2.0)

    async def _broadcast_update(self) -> None:
        if self._broadcaster:
            from cortex.api.protocol import CortexMessage, MessageType

            msg = CortexMessage(
                type=MessageType.SIMULATION_UPDATE,
                payload=self.stats,
            )
            await self._broadcaster.broadcast(msg)

    @property
    def stats(self) -> dict:
        elapsed = time.time() - self._start_time if self._start_time else 0
        return {
            **self._portfolio.snapshot(),
            "running": self._running,
            "elapsed_seconds": elapsed,
        }

    def to_dict(self) -> dict:
        return {
            "running": self._running,
            "portfolio_nav": self._portfolio.nav,
            "num_trades": len(self._portfolio.trades),
        }
