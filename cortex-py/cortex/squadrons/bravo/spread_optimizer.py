"""BRAVO Spread Optimizer -- multi-leg options spread execution agent.

Receives OPTIONS_ENTRY / OPTIONS_EXIT signals from CHARLIE squadron and
constructs, analyses, and submits multi-leg option spreads.  Supports
verticals, iron condors, calendars, straddles, and strangles.

Pipeline position: CHARLIE (OPTIONS_ENTRY/EXIT) -> BRAVO (Spread Optimizer)
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


# ---------------------------------------------------------------------------
# Enums
# ---------------------------------------------------------------------------

class SpreadType(str, Enum):
    VERTICAL_CALL = "vertical_call"
    VERTICAL_PUT = "vertical_put"
    IRON_CONDOR = "iron_condor"
    CALENDAR = "calendar"
    STRADDLE = "straddle"
    STRANGLE = "strangle"


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class SpreadLeg:
    symbol: str
    option_type: str  # "call" / "put"
    strike: float
    expiry: str  # ISO date string e.g. "2026-03-20"
    side: str  # "buy" / "sell"
    quantity: int
    limit_price: float | None = None


@dataclass
class SpreadOrder:
    spread_id: str
    spread_type: SpreadType
    legs: list[SpreadLeg]
    max_debit: float | None = None  # for debit spreads
    min_credit: float | None = None  # for credit spreads
    status: str = "pending"
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))


@dataclass
class SpreadResult:
    spread_id: str
    status: str  # filled / partial / rejected
    legs_filled: list[dict]  # fill details per leg
    net_premium: float
    max_risk: float
    max_reward: float


# ---------------------------------------------------------------------------
# Spread Optimizer Agent
# ---------------------------------------------------------------------------

class SpreadOptimizer(BaseAgent):
    """BRAVO squadron multi-leg options spread execution agent.

    Subscribes to OPTIONS_ENTRY and OPTIONS_EXIT signals from CHARLIE
    squadron, constructs spread orders, analyses risk/reward, and submits
    them for simulated or live execution.
    """

    agent_id = "spread_optimizer"
    squadron = "bravo"
    subscriptions = [SignalTypes.OPTIONS_ENTRY, SignalTypes.OPTIONS_EXIT]

    def __init__(self, bus: SignalBus, simulation: bool = True) -> None:
        super().__init__(bus)
        self._simulation = simulation
        self._active_spreads: list[SpreadOrder] = []
        self._completed_spreads: list[SpreadResult] = []

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def active_spreads(self) -> list[SpreadOrder]:
        """Return all spread orders that are still active (pending/partial)."""
        return list(self._active_spreads)

    # ------------------------------------------------------------------
    # Signal handling
    # ------------------------------------------------------------------

    async def handle_signal(self, signal: Signal) -> None:
        """Route incoming options signals to spread construction."""
        if signal.signal_type == SignalTypes.OPTIONS_ENTRY:
            await self._handle_options_entry(signal)
        elif signal.signal_type == SignalTypes.OPTIONS_EXIT:
            await self._handle_options_exit(signal)

    async def _handle_options_entry(self, signal: Signal) -> None:
        """Construct and submit a spread from an OPTIONS_ENTRY signal."""
        payload = signal.payload
        spread_type_str = payload.get("spread_type", "")
        symbol = payload.get("symbol", "")
        quantity = payload.get("quantity", 1)
        expiry = payload.get("expiry", "")

        order: SpreadOrder | None = None

        if spread_type_str == SpreadType.VERTICAL_CALL.value:
            order = self.build_vertical(
                symbol=symbol,
                option_type="call",
                long_strike=payload.get("long_strike", 0.0),
                short_strike=payload.get("short_strike", 0.0),
                expiry=expiry,
                quantity=quantity,
            )
        elif spread_type_str == SpreadType.VERTICAL_PUT.value:
            order = self.build_vertical(
                symbol=symbol,
                option_type="put",
                long_strike=payload.get("long_strike", 0.0),
                short_strike=payload.get("short_strike", 0.0),
                expiry=expiry,
                quantity=quantity,
            )
        elif spread_type_str == SpreadType.IRON_CONDOR.value:
            order = self.build_iron_condor(
                symbol=symbol,
                put_long=payload.get("put_long", 0.0),
                put_short=payload.get("put_short", 0.0),
                call_short=payload.get("call_short", 0.0),
                call_long=payload.get("call_long", 0.0),
                expiry=expiry,
                quantity=quantity,
            )
        elif spread_type_str == SpreadType.CALENDAR.value:
            order = self.build_calendar(
                symbol=symbol,
                option_type=payload.get("option_type", "call"),
                strike=payload.get("strike", 0.0),
                near_expiry=payload.get("near_expiry", ""),
                far_expiry=payload.get("far_expiry", ""),
                quantity=quantity,
            )

        if order is not None:
            result = await self.submit_spread(order)
            log.info(
                "spread.entry_processed",
                spread_id=result.spread_id,
                status=result.status,
                net_premium=result.net_premium,
            )

    async def _handle_options_exit(self, signal: Signal) -> None:
        """Close or adjust an existing spread position."""
        payload = signal.payload
        spread_id = payload.get("spread_id", "")

        # Find the active spread and mark it closed
        for spread in self._active_spreads:
            if spread.spread_id == spread_id:
                spread.status = "closed"
                self._active_spreads.remove(spread)
                log.info("spread.exit_processed", spread_id=spread_id)
                await self.emit(
                    SignalTypes.ORDER_FILLED,
                    payload={
                        "spread_id": spread_id,
                        "action": "close",
                    },
                    priority=SignalPriority.HIGH,
                )
                return

        log.warning("spread.exit_not_found", spread_id=spread_id)

    # ------------------------------------------------------------------
    # Spread builders
    # ------------------------------------------------------------------

    def build_vertical(
        self,
        symbol: str,
        option_type: str,
        long_strike: float,
        short_strike: float,
        expiry: str,
        quantity: int,
    ) -> SpreadOrder:
        """Build a vertical spread (bull call or bear put).

        For a bull call spread: buy the lower strike, sell the higher strike.
        For a bear put spread: buy the higher strike, sell the lower strike.
        """
        spread_type = (
            SpreadType.VERTICAL_CALL if option_type == "call"
            else SpreadType.VERTICAL_PUT
        )

        legs = [
            SpreadLeg(
                symbol=symbol,
                option_type=option_type,
                strike=long_strike,
                expiry=expiry,
                side="buy",
                quantity=quantity,
            ),
            SpreadLeg(
                symbol=symbol,
                option_type=option_type,
                strike=short_strike,
                expiry=expiry,
                side="sell",
                quantity=quantity,
            ),
        ]

        spread_id = self._generate_spread_id()
        return SpreadOrder(
            spread_id=spread_id,
            spread_type=spread_type,
            legs=legs,
        )

    def build_iron_condor(
        self,
        symbol: str,
        put_long: float,
        put_short: float,
        call_short: float,
        call_long: float,
        expiry: str,
        quantity: int,
    ) -> SpreadOrder:
        """Build an iron condor (4 legs).

        Legs:
          1. Buy put  @ put_long   (OTM protective put)
          2. Sell put  @ put_short  (short put)
          3. Sell call @ call_short (short call)
          4. Buy call  @ call_long  (OTM protective call)
        """
        legs = [
            SpreadLeg(
                symbol=symbol,
                option_type="put",
                strike=put_long,
                expiry=expiry,
                side="buy",
                quantity=quantity,
            ),
            SpreadLeg(
                symbol=symbol,
                option_type="put",
                strike=put_short,
                expiry=expiry,
                side="sell",
                quantity=quantity,
            ),
            SpreadLeg(
                symbol=symbol,
                option_type="call",
                strike=call_short,
                expiry=expiry,
                side="sell",
                quantity=quantity,
            ),
            SpreadLeg(
                symbol=symbol,
                option_type="call",
                strike=call_long,
                expiry=expiry,
                side="buy",
                quantity=quantity,
            ),
        ]

        spread_id = self._generate_spread_id()
        return SpreadOrder(
            spread_id=spread_id,
            spread_type=SpreadType.IRON_CONDOR,
            legs=legs,
        )

    def build_calendar(
        self,
        symbol: str,
        option_type: str,
        strike: float,
        near_expiry: str,
        far_expiry: str,
        quantity: int,
    ) -> SpreadOrder:
        """Build a calendar spread (same strike, different expiries).

        Sell the near-term option, buy the far-term option.
        """
        legs = [
            SpreadLeg(
                symbol=symbol,
                option_type=option_type,
                strike=strike,
                expiry=near_expiry,
                side="sell",
                quantity=quantity,
            ),
            SpreadLeg(
                symbol=symbol,
                option_type=option_type,
                strike=strike,
                expiry=far_expiry,
                side="buy",
                quantity=quantity,
            ),
        ]

        spread_id = self._generate_spread_id()
        return SpreadOrder(
            spread_id=spread_id,
            spread_type=SpreadType.CALENDAR,
            legs=legs,
        )

    # ------------------------------------------------------------------
    # Spread analysis
    # ------------------------------------------------------------------

    def analyze_spread(self, order: SpreadOrder) -> dict:
        """Compute max_risk, max_reward, and breakeven for a spread.

        Uses limit_price on each leg when available; falls back to
        strike-width heuristics for risk/reward.
        """
        if order.spread_type in (SpreadType.VERTICAL_CALL, SpreadType.VERTICAL_PUT):
            return self._analyze_vertical(order)
        elif order.spread_type == SpreadType.IRON_CONDOR:
            return self._analyze_iron_condor(order)
        elif order.spread_type == SpreadType.CALENDAR:
            return self._analyze_calendar(order)

        return {"max_risk": 0.0, "max_reward": 0.0, "breakeven": []}

    def _analyze_vertical(self, order: SpreadOrder) -> dict:
        """Vertical spread analysis.

        For a debit spread (e.g. bull call):
          - net_debit = buy_premium - sell_premium
          - max_risk  = net_debit (per contract * 100 shares)
          - max_reward = strike_width - net_debit
          - breakeven = long_strike + net_debit  (call) or
                        long_strike - net_debit  (put)
        """
        buy_leg = next(l for l in order.legs if l.side == "buy")
        sell_leg = next(l for l in order.legs if l.side == "sell")

        buy_price = buy_leg.limit_price if buy_leg.limit_price is not None else 0.0
        sell_price = sell_leg.limit_price if sell_leg.limit_price is not None else 0.0

        strike_width = abs(buy_leg.strike - sell_leg.strike)
        net_debit = buy_price - sell_price

        max_risk = abs(net_debit) * buy_leg.quantity * 100
        max_reward = (strike_width - abs(net_debit)) * buy_leg.quantity * 100

        if order.spread_type == SpreadType.VERTICAL_CALL:
            breakeven = buy_leg.strike + abs(net_debit)
        else:
            breakeven = buy_leg.strike - abs(net_debit)

        return {
            "max_risk": max_risk,
            "max_reward": max_reward,
            "breakeven": [breakeven],
            "net_debit": net_debit,
            "strike_width": strike_width,
        }

    def _analyze_iron_condor(self, order: SpreadOrder) -> dict:
        """Iron condor analysis.

        An iron condor is a credit spread:
          - net_credit = (sell_put_prem + sell_call_prem) - (buy_put_prem + buy_call_prem)
          - max_reward = net_credit
          - put_width  = put_short_strike - put_long_strike
          - call_width = call_long_strike - call_short_strike
          - max_risk   = max(put_width, call_width) - net_credit
          - breakevens: put_short - net_credit, call_short + net_credit
        """
        put_legs = [l for l in order.legs if l.option_type == "put"]
        call_legs = [l for l in order.legs if l.option_type == "call"]

        put_buy = next(l for l in put_legs if l.side == "buy")
        put_sell = next(l for l in put_legs if l.side == "sell")
        call_sell = next(l for l in call_legs if l.side == "sell")
        call_buy = next(l for l in call_legs if l.side == "buy")

        def _price(leg: SpreadLeg) -> float:
            return leg.limit_price if leg.limit_price is not None else 0.0

        net_credit = (
            _price(put_sell) + _price(call_sell)
            - _price(put_buy) - _price(call_buy)
        )

        put_width = put_sell.strike - put_buy.strike
        call_width = call_buy.strike - call_sell.strike
        wing_width = max(put_width, call_width)
        quantity = put_buy.quantity

        max_reward = net_credit * quantity * 100
        max_risk = (wing_width - net_credit) * quantity * 100

        lower_be = put_sell.strike - net_credit
        upper_be = call_sell.strike + net_credit

        return {
            "max_risk": max_risk,
            "max_reward": max_reward,
            "breakeven": [lower_be, upper_be],
            "net_credit": net_credit,
            "put_width": put_width,
            "call_width": call_width,
        }

    def _analyze_calendar(self, order: SpreadOrder) -> dict:
        """Calendar spread analysis.

        Calendar spreads have limited theoretical analysis without IV
        modelling. We report the net debit and flag that max risk = debit.
        """
        buy_leg = next(l for l in order.legs if l.side == "buy")
        sell_leg = next(l for l in order.legs if l.side == "sell")

        buy_price = buy_leg.limit_price if buy_leg.limit_price is not None else 0.0
        sell_price = sell_leg.limit_price if sell_leg.limit_price is not None else 0.0

        net_debit = buy_price - sell_price
        quantity = buy_leg.quantity

        return {
            "max_risk": abs(net_debit) * quantity * 100,
            "max_reward": 0.0,  # undefined without IV model
            "breakeven": [buy_leg.strike],
            "net_debit": net_debit,
        }

    # ------------------------------------------------------------------
    # Spread submission
    # ------------------------------------------------------------------

    async def submit_spread(self, order: SpreadOrder) -> SpreadResult:
        """Submit a spread for execution (simulated or live).

        Executes legs in optimal order: sell legs first to collect credit
        before paying debit on buy legs, reducing capital requirements.
        """
        ordered_legs = self._optimal_leg_order(order.legs)
        order.status = "submitted"
        self._active_spreads.append(order)

        log.info(
            "spread.submitted",
            spread_id=order.spread_id,
            spread_type=order.spread_type.value,
            num_legs=len(order.legs),
        )

        await self.emit(
            SignalTypes.ORDER_SUBMITTED,
            payload={
                "spread_id": order.spread_id,
                "spread_type": order.spread_type.value,
                "num_legs": len(order.legs),
            },
            priority=SignalPriority.HIGH,
        )

        if self._simulation:
            return self._simulate_spread_fill(order, ordered_legs)

        # Live execution placeholder
        return SpreadResult(
            spread_id=order.spread_id,
            status="submitted",
            legs_filled=[],
            net_premium=0.0,
            max_risk=0.0,
            max_reward=0.0,
        )

    def _simulate_spread_fill(
        self, order: SpreadOrder, ordered_legs: list[SpreadLeg]
    ) -> SpreadResult:
        """Simulate fills for all legs in the spread."""
        legs_filled: list[dict] = []
        net_premium = 0.0

        for leg in ordered_legs:
            fill_price = leg.limit_price if leg.limit_price is not None else 1.0
            fill_detail = {
                "symbol": leg.symbol,
                "option_type": leg.option_type,
                "strike": leg.strike,
                "expiry": leg.expiry,
                "side": leg.side,
                "quantity": leg.quantity,
                "fill_price": fill_price,
                "filled_at": datetime.now(timezone.utc).isoformat(),
            }
            legs_filled.append(fill_detail)

            # Credit for sells, debit for buys
            if leg.side == "sell":
                net_premium += fill_price * leg.quantity * 100
            else:
                net_premium -= fill_price * leg.quantity * 100

        # Compute risk/reward via analyze
        analysis = self.analyze_spread(order)

        order.status = "filled"
        self._active_spreads = [
            s for s in self._active_spreads if s.spread_id != order.spread_id
        ]

        result = SpreadResult(
            spread_id=order.spread_id,
            status="filled",
            legs_filled=legs_filled,
            net_premium=net_premium,
            max_risk=analysis.get("max_risk", 0.0),
            max_reward=analysis.get("max_reward", 0.0),
        )
        self._completed_spreads.append(result)

        log.info(
            "spread.sim_filled",
            spread_id=order.spread_id,
            legs=len(legs_filled),
            net_premium=net_premium,
        )

        return result

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _optimal_leg_order(self, legs: list[SpreadLeg]) -> list[SpreadLeg]:
        """Sort legs so sell legs execute first, then buy legs.

        Selling first collects credit before paying debit on buy legs,
        which reduces the net capital requirement during execution.
        """
        sell_legs = [l for l in legs if l.side == "sell"]
        buy_legs = [l for l in legs if l.side == "buy"]
        return sell_legs + buy_legs

    @staticmethod
    def _generate_spread_id() -> str:
        """Generate a unique spread identifier."""
        return f"SPR-{uuid.uuid4().hex[:12].upper()}"

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "simulation": self._simulation,
            "active_spread_count": len(self._active_spreads),
            "completed_spread_count": len(self._completed_spreads),
            "active_spread_ids": [s.spread_id for s in self._active_spreads],
        })
        return base
