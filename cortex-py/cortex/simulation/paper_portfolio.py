"""Paper trading portfolio for simulation mode."""

import time
from dataclasses import dataclass, field

import structlog

log = structlog.get_logger()


@dataclass
class PaperPosition:
    symbol: str
    quantity: int
    avg_price: float
    current_price: float = 0.0

    @property
    def market_value(self) -> float:
        return self.quantity * self.current_price

    @property
    def unrealized_pnl(self) -> float:
        return self.quantity * (self.current_price - self.avg_price)

    @property
    def pnl_pct(self) -> float:
        if self.avg_price == 0:
            return 0.0
        return ((self.current_price - self.avg_price) / self.avg_price) * 100

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "quantity": self.quantity,
            "avg_price": self.avg_price,
            "current_price": self.current_price,
            "market_value": self.market_value,
            "unrealized_pnl": self.unrealized_pnl,
            "pnl_pct": self.pnl_pct,
        }


@dataclass
class PaperTrade:
    symbol: str
    side: str  # "buy" or "sell"
    quantity: int
    price: float
    commission: float = 0.0
    timestamp: float = field(default_factory=time.time)
    pnl: float = 0.0  # realized P&L for sells

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "side": self.side,
            "quantity": self.quantity,
            "price": self.price,
            "commission": self.commission,
            "timestamp": self.timestamp,
            "pnl": self.pnl,
        }


class PaperPortfolio:
    def __init__(self, starting_capital: float = 100_000.0):
        self.cash = starting_capital
        self.starting_capital = starting_capital
        self.positions: dict[str, PaperPosition] = {}
        self.trades: list[PaperTrade] = []
        self._equity_curve: list[tuple[float, float]] = []  # (timestamp, nav)
        self._peak_nav = starting_capital

    @property
    def nav(self) -> float:
        positions_value = sum(p.market_value for p in self.positions.values())
        return self.cash + positions_value

    @property
    def total_pnl(self) -> float:
        return self.nav - self.starting_capital

    @property
    def total_return_pct(self) -> float:
        if self.starting_capital == 0:
            return 0.0
        return (self.total_pnl / self.starting_capital) * 100

    @property
    def max_drawdown(self) -> float:
        if self._peak_nav == 0:
            return 0.0
        return ((self._peak_nav - self.nav) / self._peak_nav) * 100

    @property
    def win_rate(self) -> float:
        closed = [t for t in self.trades if t.side == "sell"]
        if not closed:
            return 0.0
        winners = sum(1 for t in closed if t.pnl > 0)
        return winners / len(closed)

    def buy(
        self, symbol: str, quantity: int, price: float, commission: float = 0.0
    ) -> PaperTrade:
        cost = quantity * price + commission
        if cost > self.cash:
            raise ValueError(
                f"Insufficient cash: need {cost:.2f}, have {self.cash:.2f}"
            )

        self.cash -= cost

        if symbol in self.positions:
            pos = self.positions[symbol]
            total_qty = pos.quantity + quantity
            pos.avg_price = (
                (pos.avg_price * pos.quantity) + (price * quantity)
            ) / total_qty
            pos.quantity = total_qty
        else:
            self.positions[symbol] = PaperPosition(
                symbol=symbol,
                quantity=quantity,
                avg_price=price,
                current_price=price,
            )

        trade = PaperTrade(
            symbol=symbol,
            side="buy",
            quantity=quantity,
            price=price,
            commission=commission,
        )
        self.trades.append(trade)
        self._update_peak()
        return trade

    def sell(
        self, symbol: str, quantity: int, price: float, commission: float = 0.0
    ) -> PaperTrade:
        if symbol not in self.positions:
            raise ValueError(f"No position in {symbol}")
        pos = self.positions[symbol]
        if quantity > pos.quantity:
            raise ValueError(
                f"Cannot sell {quantity} shares, only have {pos.quantity}"
            )

        pnl = quantity * (price - pos.avg_price) - commission
        self.cash += quantity * price - commission

        pos.quantity -= quantity
        if pos.quantity == 0:
            del self.positions[symbol]

        trade = PaperTrade(
            symbol=symbol,
            side="sell",
            quantity=quantity,
            price=price,
            commission=commission,
            pnl=pnl,
        )
        self.trades.append(trade)
        self._update_peak()
        return trade

    def update_price(self, symbol: str, price: float) -> None:
        if symbol in self.positions:
            self.positions[symbol].current_price = price
            self._update_peak()

    def _update_peak(self) -> None:
        nav = self.nav
        if nav > self._peak_nav:
            self._peak_nav = nav
        self._equity_curve.append((time.time(), nav))

    def snapshot(self) -> dict:
        return {
            "cash": self.cash,
            "nav": self.nav,
            "total_pnl": self.total_pnl,
            "total_return_pct": self.total_return_pct,
            "max_drawdown": self.max_drawdown,
            "win_rate": self.win_rate,
            "num_trades": len(self.trades),
            "num_positions": len(self.positions),
            "positions": {s: p.to_dict() for s, p in self.positions.items()},
            "equity_curve": self._equity_curve[-100:],  # Last 100 points
        }
