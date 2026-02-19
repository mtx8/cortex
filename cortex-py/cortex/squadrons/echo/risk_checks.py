"""Pre-trade risk checks. Every order must pass ALL checks.
Target execution time: <10ms (all in-memory, no I/O)."""

from dataclasses import dataclass, field
import time


@dataclass
class OrderRequest:
    symbol: str
    quantity: float
    estimated_price: float
    asset_class: str  # "equity" | "option" | "crypto"
    side: str  # "buy" | "sell"
    is_closing: bool = False
    stop_loss: float | None = None


@dataclass
class PortfolioState:
    nav: float
    daily_drawdown_pct: float
    weekly_drawdown_pct: float
    total_drawdown_pct: float
    position_count: int
    daily_trade_count: int


@dataclass
class CheckResult:
    approved: bool
    rejections: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    check_duration_ms: float = 0.0


class PreTradeCheck:
    def __init__(
        self,
        max_position_pct: float = 5.0,
        max_concurrent: int = 15,
        max_daily_trades: int = 50,
        daily_drawdown_halt_pct: float = 7.0,
        weekly_drawdown_halt_pct: float = 10.0,
        total_drawdown_halt_pct: float = 20.0,
        max_single_trade_loss: float = 500.0,
    ):
        self._max_position_pct = max_position_pct
        self._max_concurrent = max_concurrent
        self._max_daily_trades = max_daily_trades
        self._daily_halt = daily_drawdown_halt_pct
        self._weekly_halt = weekly_drawdown_halt_pct
        self._total_halt = total_drawdown_halt_pct
        self._max_loss = max_single_trade_loss

    def run(
        self, order: OrderRequest, portfolio: PortfolioState, is_halted: bool
    ) -> CheckResult:
        start = time.perf_counter()
        rejections: list[str] = []
        warnings: list[str] = []

        # CHECK 1: Kill switch
        if is_halted:
            rejections.append("System is HALTED. No orders permitted.")
            return CheckResult(
                approved=False,
                rejections=rejections,
                check_duration_ms=(time.perf_counter() - start) * 1000,
            )

        # Closing positions bypass most checks
        if order.is_closing:
            return CheckResult(
                approved=True,
                check_duration_ms=(time.perf_counter() - start) * 1000,
            )

        # CHECK 2: Drawdown halt
        if portfolio.daily_drawdown_pct >= self._daily_halt:
            rejections.append(
                f"Daily drawdown {portfolio.daily_drawdown_pct:.1f}% >= halt {self._daily_halt}%"
            )
        if portfolio.weekly_drawdown_pct >= self._weekly_halt:
            rejections.append(
                f"Weekly drawdown {portfolio.weekly_drawdown_pct:.1f}% >= halt {self._weekly_halt}%"
            )
        if portfolio.total_drawdown_pct >= self._total_halt:
            rejections.append(
                f"Total drawdown {portfolio.total_drawdown_pct:.1f}% >= halt {self._total_halt}%"
            )

        # CHECK 3: Position sizing
        order_value = order.quantity * order.estimated_price
        position_pct = (order_value / portfolio.nav) * 100 if portfolio.nav > 0 else 100
        if position_pct > self._max_position_pct:
            rejections.append(
                f"Position size {position_pct:.1f}% exceeds max {self._max_position_pct}%"
            )

        # CHECK 4: Concurrent positions
        if portfolio.position_count >= self._max_concurrent:
            rejections.append(
                f"At max concurrent positions ({self._max_concurrent})"
            )

        # CHECK 5: Daily trade count
        if portfolio.daily_trade_count >= self._max_daily_trades:
            rejections.append(f"Daily trade limit ({self._max_daily_trades}) reached")

        duration = (time.perf_counter() - start) * 1000
        return CheckResult(
            approved=len(rejections) == 0,
            rejections=rejections,
            warnings=warnings,
            check_duration_ms=duration,
        )
