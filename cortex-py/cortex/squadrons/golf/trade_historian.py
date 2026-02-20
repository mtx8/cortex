"""Trade Historian — records every trade with full context for learning.

Captures:
- Entry/exit signals that triggered the trade
- Market conditions at time of trade (regime, volatility, sector strength)
- Execution quality (slippage, fill time)
- Outcome (P&L, holding period, max adverse excursion)

This data feeds PatternLearner, StrategyOptimizer, and DrawdownAnalyzer.
"""

import time
from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


@dataclass
class TradeRecord:
    """Immutable record of a completed trade with full context."""

    trade_id: str
    symbol: str
    direction: str  # "long" | "short"
    entry_price: float
    exit_price: float
    quantity: int
    pnl: float
    pnl_pct: float
    entry_time: float
    exit_time: float
    holding_period_seconds: float
    strategy: str
    entry_reasons: list[str] = field(default_factory=list)
    exit_reasons: list[str] = field(default_factory=list)
    regime: str = "unknown"
    sector: str = "unknown"
    slippage: float = 0.0
    max_adverse_excursion: float = 0.0
    max_favorable_excursion: float = 0.0


class TradeHistorian(BaseAgent):
    """Records every completed trade with full metadata for the learning pipeline."""

    agent_id = "trade_historian"
    squadron = "golf"
    subscriptions = [
        SignalTypes.ORDER_FILLED,
        SignalTypes.SLIPPAGE_REPORT,
    ]

    def __init__(self, bus: SignalBus, max_records: int = 10000):
        super().__init__(bus)
        self._max_records = max_records
        self._trades: list[TradeRecord] = []
        self._pending_entries: dict[str, dict] = {}  # symbol -> entry context
        self._total_recorded = 0

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload

        if signal.signal_type == SignalTypes.ORDER_FILLED:
            await self._process_fill(payload)
        elif signal.signal_type == SignalTypes.SLIPPAGE_REPORT:
            self._update_slippage(payload)

    async def _process_fill(self, payload: dict) -> None:
        symbol = payload.get("symbol", "")
        side = payload.get("side", "")
        price = payload.get("fill_price", payload.get("price", 0.0))
        quantity = payload.get("quantity", 0)

        if not symbol:
            return

        if side == "buy":
            # Opening a position — store as pending entry
            self._pending_entries[symbol] = {
                "entry_price": price,
                "quantity": quantity,
                "entry_time": time.time(),
                "strategy": payload.get("strategy", "unknown"),
                "entry_reasons": payload.get("reasons", []),
                "direction": payload.get("direction", "long"),
            }
        elif side == "sell" and symbol in self._pending_entries:
            # Closing a position — create trade record
            entry = self._pending_entries.pop(symbol)
            entry_price = entry["entry_price"]
            direction = entry["direction"]

            if direction == "long":
                pnl = (price - entry_price) * quantity
            else:
                pnl = (entry_price - price) * quantity

            pnl_pct = (pnl / (entry_price * quantity)) * 100 if entry_price > 0 else 0.0
            now = time.time()

            record = TradeRecord(
                trade_id=f"{symbol}_{self._total_recorded}",
                symbol=symbol,
                direction=direction,
                entry_price=entry_price,
                exit_price=price,
                quantity=quantity,
                pnl=pnl,
                pnl_pct=pnl_pct,
                entry_time=entry["entry_time"],
                exit_time=now,
                holding_period_seconds=now - entry["entry_time"],
                strategy=entry["strategy"],
                entry_reasons=entry["entry_reasons"],
                exit_reasons=payload.get("reasons", []),
            )

            self._trades.append(record)
            self._total_recorded += 1

            # Trim if over limit
            if len(self._trades) > self._max_records:
                self._trades = self._trades[-self._max_records:]

            log.info(
                "trade.recorded",
                symbol=symbol,
                pnl=round(pnl, 2),
                pnl_pct=round(pnl_pct, 2),
                total=self._total_recorded,
            )

            await self.emit(
                SignalTypes.TRADE_RECORDED,
                payload={
                    "trade_id": record.trade_id,
                    "symbol": record.symbol,
                    "pnl": record.pnl,
                    "pnl_pct": record.pnl_pct,
                    "strategy": record.strategy,
                    "holding_period": record.holding_period_seconds,
                },
                priority=SignalPriority.LOW,
            )

    def _update_slippage(self, payload: dict) -> None:
        """Update the most recent trade record with slippage data."""
        symbol = payload.get("symbol", "")
        slippage = payload.get("slippage", 0.0)
        if self._trades and self._trades[-1].symbol == symbol:
            self._trades[-1].slippage = slippage

    @property
    def trades(self) -> list[TradeRecord]:
        return list(self._trades)

    @property
    def winning_trades(self) -> list[TradeRecord]:
        return [t for t in self._trades if t.pnl > 0]

    @property
    def losing_trades(self) -> list[TradeRecord]:
        return [t for t in self._trades if t.pnl <= 0]

    def to_dict(self) -> dict:
        base = super().to_dict()
        win_count = len(self.winning_trades)
        total = len(self._trades)
        base.update({
            "total_recorded": self._total_recorded,
            "trades_in_memory": total,
            "pending_entries": len(self._pending_entries),
            "win_rate": round(win_count / total, 3) if total > 0 else 0.0,
        })
        return base
