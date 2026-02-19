"""FOXTROT Harvest Bot — identifies tax-loss harvesting opportunities.

Scans a portfolio for positions trading below their cost basis and ranks
them by potential tax savings.  This agent operates in **identification mode
only** — it never executes trades.  When an opportunity clears all filters
it emits a TAX_HARVEST_SIGNAL so downstream agents (BRAVO) can act.

Key concepts:
  * HarvestOpportunity — a dataclass describing one harvestable position.
  * HarvestConfig — tunable thresholds (min loss, tax rates, daily caps).
  * The bot delegates wash-sale safety checks to the WashSaleGuard agent
    so that no harvested sale would inadvertently disallow a prior loss.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
import structlog

from cortex.orchestrator.bus import Signal, SignalBus
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent
from cortex.squadrons.foxtrot.wash_sale_guard import WashSaleGuard

log = structlog.get_logger()


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class HarvestOpportunity:
    """A single tax-loss harvesting opportunity."""

    symbol: str
    current_price: float
    cost_basis: float              # average across lots
    unrealized_loss: float         # total dollar loss (negative value stored as positive)
    quantity: int                  # total harvestable shares
    loss_pct: float                # percentage loss (0.10 = 10 %)
    holding_period_days: int       # from oldest lot
    is_long_term: bool             # held > 365 days
    wash_sale_safe: bool           # no recent sells that would block
    estimated_tax_savings: float   # unrealized_loss * effective tax rate
    priority_score: float          # higher = harvest first

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "current_price": self.current_price,
            "cost_basis": self.cost_basis,
            "unrealized_loss": self.unrealized_loss,
            "quantity": self.quantity,
            "loss_pct": round(self.loss_pct, 4),
            "holding_period_days": self.holding_period_days,
            "is_long_term": self.is_long_term,
            "wash_sale_safe": self.wash_sale_safe,
            "estimated_tax_savings": round(self.estimated_tax_savings, 2),
            "priority_score": round(self.priority_score, 4),
        }


@dataclass
class HarvestConfig:
    """Tunable parameters for the harvest scanner."""

    min_loss_usd: float = 100.0       # minimum dollar loss to consider
    min_loss_pct: float = 0.05        # 5 % minimum loss percentage
    tax_rate_short: float = 0.37      # short-term federal rate
    tax_rate_long: float = 0.20       # long-term federal rate
    state_tax_rate: float = 0.05      # state estimate
    max_harvest_per_day: int = 5      # avoid over-trading
    respect_wash_sales: bool = True   # check wash sale guard


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

class HarvestBot(BaseAgent):
    """Identifies tax-loss harvesting opportunities in a portfolio.

    This agent does **not** subscribe to any signals — it runs on a
    schedule (or on demand) and emits TAX_HARVEST_SIGNAL when it finds
    actionable opportunities.
    """

    agent_id: str = "harvest_bot"
    squadron: str = "foxtrot"
    subscriptions: list[str] = []

    def __init__(
        self,
        bus: SignalBus,
        wash_sale_guard: WashSaleGuard,
        config: HarvestConfig | None = None,
    ) -> None:
        super().__init__(bus)
        self._wash_sale_guard = wash_sale_guard
        self._config = config or HarvestConfig()

    # ------------------------------------------------------------------
    # Core scanning
    # ------------------------------------------------------------------

    def scan_portfolio(
        self,
        positions: dict[str, dict],
        as_of: date | None = None,
    ) -> list[HarvestOpportunity]:
        """Scan *positions* and return harvest opportunities sorted by priority.

        Parameters
        ----------
        positions:
            Mapping of symbol -> position dict.  Each position dict must
            contain at least:
                quantity      : int
                cost_basis    : float   (average per-share cost)
                current_price : float
                acquired_date : str     (ISO-8601 date, e.g. "2025-01-15")
        as_of:
            The reference date for holding-period and wash-sale calculations.
            Defaults to today.
        """
        as_of = as_of or date.today()

        # Pre-fetch blocked symbols once so we don't query per-position.
        if self._config.respect_wash_sales:
            blocked_symbols = set(
                self._wash_sale_guard.get_blocked_symbols(as_of)
            )
        else:
            blocked_symbols: set[str] = set()

        opportunities: list[HarvestOpportunity] = []

        for symbol, pos in positions.items():
            opp = self._evaluate_position(symbol, pos, as_of, blocked_symbols)
            if opp is not None:
                opportunities.append(opp)

        # Sort by priority_score descending (best opportunities first).
        opportunities.sort(key=lambda o: o.priority_score, reverse=True)
        return opportunities

    def get_top_opportunities(
        self,
        positions: dict[str, dict],
        count: int = 5,
        as_of: date | None = None,
    ) -> list[HarvestOpportunity]:
        """Return the top *count* harvest opportunities."""
        all_opps = self.scan_portfolio(positions, as_of=as_of)
        return all_opps[:count]

    # ------------------------------------------------------------------
    # Savings estimation
    # ------------------------------------------------------------------

    def estimate_annual_savings(
        self, opportunities: list[HarvestOpportunity],
    ) -> dict:
        """Aggregate estimated tax savings across a set of opportunities.

        Returns a dict with:
            total_savings      — combined short + long term
            short_term_savings — savings from short-term lots
            long_term_savings  — savings from long-term lots
        """
        short_term = sum(
            o.estimated_tax_savings for o in opportunities if not o.is_long_term
        )
        long_term = sum(
            o.estimated_tax_savings for o in opportunities if o.is_long_term
        )
        return {
            "total_savings": round(short_term + long_term, 2),
            "short_term_savings": round(short_term, 2),
            "long_term_savings": round(long_term, 2),
        }

    # ------------------------------------------------------------------
    # Signal handling (no-op — this agent runs on schedule)
    # ------------------------------------------------------------------

    async def handle_signal(self, signal: Signal) -> None:
        """No-op.  HarvestBot does not react to inbound signals."""
        pass

    # ------------------------------------------------------------------
    # Signal emission helper
    # ------------------------------------------------------------------

    async def emit_opportunities(
        self, opportunities: list[HarvestOpportunity],
    ) -> None:
        """Emit a TAX_HARVEST_SIGNAL for each opportunity."""
        for opp in opportunities:
            await self.emit(
                SignalTypes.TAX_HARVEST_SIGNAL,
                payload=opp.to_dict(),
            )
            log.info(
                "harvest_bot.opportunity_emitted",
                symbol=opp.symbol,
                unrealized_loss=opp.unrealized_loss,
                estimated_tax_savings=opp.estimated_tax_savings,
            )

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "config": {
                "min_loss_usd": self._config.min_loss_usd,
                "min_loss_pct": self._config.min_loss_pct,
                "tax_rate_short": self._config.tax_rate_short,
                "tax_rate_long": self._config.tax_rate_long,
                "state_tax_rate": self._config.state_tax_rate,
                "max_harvest_per_day": self._config.max_harvest_per_day,
                "respect_wash_sales": self._config.respect_wash_sales,
            },
        })
        return base

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _evaluate_position(
        self,
        symbol: str,
        pos: dict,
        as_of: date,
        blocked_symbols: set[str],
    ) -> HarvestOpportunity | None:
        """Evaluate a single position and return an opportunity or None."""
        quantity: int = int(pos["quantity"])
        cost_basis: float = float(pos["cost_basis"])
        current_price: float = float(pos["current_price"])
        acquired_date: date = (
            date.fromisoformat(pos["acquired_date"])
            if isinstance(pos["acquired_date"], str)
            else pos["acquired_date"]
        )

        # --- unrealized loss ---
        unrealized_pnl = (current_price - cost_basis) * quantity
        if unrealized_pnl >= 0:
            # No loss — nothing to harvest.
            return None

        unrealized_loss = abs(unrealized_pnl)
        loss_pct = abs(current_price - cost_basis) / cost_basis

        # --- threshold filters ---
        if unrealized_loss < self._config.min_loss_usd:
            return None
        if loss_pct < self._config.min_loss_pct:
            return None

        # --- holding period ---
        holding_period_days = (as_of - acquired_date).days
        is_long_term = holding_period_days > 365

        # --- tax savings ---
        if is_long_term:
            effective_rate = self._config.tax_rate_long + self._config.state_tax_rate
        else:
            effective_rate = self._config.tax_rate_short + self._config.state_tax_rate

        estimated_tax_savings = unrealized_loss * effective_rate

        # --- wash sale safety ---
        wash_sale_safe = symbol not in blocked_symbols

        # --- priority scoring ---
        # Larger losses and shorter holding periods (short-term has higher
        # tax benefit) produce higher priority.  A simple multiplicative
        # score:  dollar savings * inverse-holding-period weight.
        holding_weight = 1.0 / max(holding_period_days, 1)
        priority_score = unrealized_loss * holding_weight

        return HarvestOpportunity(
            symbol=symbol,
            current_price=current_price,
            cost_basis=cost_basis,
            unrealized_loss=unrealized_loss,
            quantity=quantity,
            loss_pct=loss_pct,
            holding_period_days=holding_period_days,
            is_long_term=is_long_term,
            wash_sale_safe=wash_sale_safe,
            estimated_tax_savings=estimated_tax_savings,
            priority_score=priority_score,
        )
