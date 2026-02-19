"""Comprehensive tests for the FOXTROT Wash Sale Guard.

All dates are deterministic using datetime.date.
Follows existing CORTEX test patterns (pytest + pytest-asyncio).
"""

import asyncio
from datetime import date, timedelta

import pytest

from cortex.orchestrator.bus import Signal, SignalBus, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.foxtrot.wash_sale_guard import (
    LotRecord,
    WashSaleCheck,
    WashSaleGuard,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_guard() -> WashSaleGuard:
    bus = SignalBus()
    return WashSaleGuard(bus)


def _make_signal(
    symbol: str,
    side: str,
    quantity: float,
    price: float,
    fill_date: str,
) -> Signal:
    return Signal(
        signal_id=f"test_{symbol}_{side}",
        source_agent="test_broker",
        source_squadron="bravo",
        signal_type=SignalTypes.ORDER_FILLED,
        payload={
            "symbol": symbol,
            "side": side,
            "quantity": quantity,
            "price": price,
            "fill_date": fill_date,
        },
        priority=SignalPriority.NORMAL,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestRecordBuy:
    def test_record_buy_creates_lot(self):
        guard = _make_guard()
        lot = guard.record_buy("AAPL", 100, 150.0, date(2025, 1, 15))

        assert lot.symbol == "AAPL"
        assert lot.quantity == 100
        assert lot.cost_basis == 150.0
        assert lot.acquired_date == date(2025, 1, 15)
        assert lot.sold_date is None
        assert lot.sold_price is None
        assert lot.is_loss is False
        assert lot.wash_sale_disallowed == 0.0
        assert lot.adjusted_cost_basis is None

        # Lot is tracked in the ledger
        lots = guard.get_tax_lots("AAPL")
        assert len(lots) == 1
        assert lots[0] is lot


class TestRecordSellFIFO:
    def test_record_sell_fifo_matching(self):
        """Sells match the oldest (first-bought) lots first."""
        guard = _make_guard()
        guard.record_buy("MSFT", 50, 200.0, date(2025, 1, 1))
        guard.record_buy("MSFT", 50, 220.0, date(2025, 1, 10))

        matched = guard.record_sell("MSFT", 50, 210.0, date(2025, 2, 1))

        assert len(matched) == 1
        assert matched[0].cost_basis == 200.0  # oldest lot matched first
        assert matched[0].sold_price == 210.0
        assert matched[0].sold_date == date(2025, 2, 1)

    def test_multiple_lots_fifo(self):
        """Selling quantity spanning multiple lots consumes them in order."""
        guard = _make_guard()
        guard.record_buy("TSLA", 30, 100.0, date(2025, 1, 1))
        guard.record_buy("TSLA", 30, 110.0, date(2025, 1, 5))
        guard.record_buy("TSLA", 30, 120.0, date(2025, 1, 10))

        matched = guard.record_sell("TSLA", 70, 115.0, date(2025, 2, 15))

        # Should fully consume lot 1 (30) and lot 2 (30), then partial lot 3 (10)
        assert len(matched) == 3
        assert matched[0].quantity == 30
        assert matched[0].cost_basis == 100.0
        assert matched[1].quantity == 30
        assert matched[1].cost_basis == 110.0
        assert matched[2].quantity == 10
        assert matched[2].cost_basis == 120.0

        # Remaining open lot should have 20 shares at $120
        open_lots = [l for l in guard.get_tax_lots("TSLA") if l.sold_date is None]
        assert len(open_lots) == 1
        assert open_lots[0].quantity == 20
        assert open_lots[0].cost_basis == 120.0


class TestLossDetection:
    def test_sell_at_loss_detection(self):
        """A lot sold below cost basis is correctly identified as a loss."""
        guard = _make_guard()
        guard.record_buy("NVDA", 100, 500.0, date(2025, 1, 1))
        matched = guard.record_sell("NVDA", 100, 450.0, date(2025, 2, 1))

        assert len(matched) == 1
        assert matched[0].is_loss is True
        assert matched[0].realized_gain == (450.0 - 500.0) * 100  # -5000

    def test_sell_at_gain_no_wash_sale(self):
        """Gains never trigger wash sale checks."""
        guard = _make_guard()
        guard.record_buy("GOOG", 50, 100.0, date(2025, 1, 1))
        guard.record_sell("GOOG", 50, 150.0, date(2025, 1, 20))

        # Buying again should NOT be blocked because the prior sale was a gain
        check = guard.check_wash_sale("GOOG", "buy", date(2025, 1, 25))
        assert check.is_blocked is False
        assert "No recent losses" in check.reason


class TestWashSaleTriggers:
    def test_buy_after_loss_triggers_wash_sale(self):
        """Buying within 30 days of a loss sale triggers wash sale."""
        guard = _make_guard()
        guard.record_buy("AMD", 100, 150.0, date(2025, 1, 1))
        guard.record_sell("AMD", 100, 120.0, date(2025, 2, 1))  # $30/share loss

        # Buy within the 30-day window
        check = guard.check_wash_sale("AMD", "buy", date(2025, 2, 15))
        assert check.is_blocked is True
        assert "Wash sale" in check.reason
        assert len(check.lookback_losses) == 1
        assert check.lookback_losses[0].is_loss is True

    def test_buy_outside_window_no_wash_sale(self):
        """Buying after 31+ days from a loss sale is fine."""
        guard = _make_guard()
        guard.record_buy("AMD", 100, 150.0, date(2025, 1, 1))
        guard.record_sell("AMD", 100, 120.0, date(2025, 2, 1))  # loss

        # Buy 31 days after the sale -> outside wash sale window
        check = guard.check_wash_sale("AMD", "buy", date(2025, 3, 4))
        assert check.is_blocked is False

    def test_wash_sale_adjusts_cost_basis(self):
        """Disallowed loss is added to the cost basis of replacement shares."""
        guard = _make_guard()
        guard.record_buy("META", 100, 300.0, date(2025, 1, 1))
        guard.record_sell("META", 100, 250.0, date(2025, 2, 1))
        # Loss = (250 - 300) * 100 = -$5,000

        # Buy replacement shares within the window
        new_lot = guard.record_buy("META", 100, 260.0, date(2025, 2, 10))

        assert new_lot.wash_sale_disallowed == 5000.0
        # Adjusted basis = purchase price + (disallowed loss / quantity)
        assert new_lot.adjusted_cost_basis == 260.0 + (5000.0 / 100)  # $310
        assert new_lot.adjusted_cost_basis == 310.0


class TestBlockedSymbols:
    def test_blocked_symbols_list(self):
        """Symbols with recent loss sales appear in the blocked list."""
        guard = _make_guard()

        # AAPL: sold at a loss recently
        guard.record_buy("AAPL", 50, 200.0, date(2025, 1, 1))
        guard.record_sell("AAPL", 50, 180.0, date(2025, 2, 1))

        # MSFT: sold at a gain — should NOT be blocked
        guard.record_buy("MSFT", 50, 300.0, date(2025, 1, 1))
        guard.record_sell("MSFT", 50, 350.0, date(2025, 2, 1))

        # GOOG: sold at a loss but >30 days ago — should NOT be blocked
        guard.record_buy("GOOG", 50, 100.0, date(2024, 11, 1))
        guard.record_sell("GOOG", 50, 80.0, date(2024, 12, 1))

        blocked = guard.get_blocked_symbols(date(2025, 2, 15))
        assert "AAPL" in blocked
        assert "MSFT" not in blocked
        assert "GOOG" not in blocked


class TestPartialLotMatching:
    def test_partial_lot_matching(self):
        """Selling fewer shares than a single lot splits the lot correctly."""
        guard = _make_guard()
        guard.record_buy("SPY", 100, 450.0, date(2025, 1, 1))

        matched = guard.record_sell("SPY", 40, 460.0, date(2025, 2, 1))

        assert len(matched) == 1
        assert matched[0].quantity == 40
        assert matched[0].sold_price == 460.0

        # Remaining open lot should have 60 shares
        open_lots = [l for l in guard.get_tax_lots("SPY") if l.sold_date is None]
        assert len(open_lots) == 1
        assert open_lots[0].quantity == 60
        assert open_lots[0].cost_basis == 450.0


class TestRealizedGains:
    def test_realized_gains_computation(self):
        """Realized gains aggregate across all sold lots for a symbol."""
        guard = _make_guard()
        guard.record_buy("AMZN", 50, 100.0, date(2025, 1, 1))
        guard.record_buy("AMZN", 50, 120.0, date(2025, 1, 5))

        # Sell first lot at gain, second lot at loss
        guard.record_sell("AMZN", 50, 130.0, date(2025, 2, 1))  # +$1500
        guard.record_sell("AMZN", 50, 110.0, date(2025, 3, 15))  # -$500

        total = guard.get_realized_gains("AMZN")
        # Lot 1: (130-100)*50 = 1500, Lot 2: (110-120)*50 = -500
        assert total == 1000.0

    def test_realized_gains_no_sales(self):
        """No sales means zero realized gains."""
        guard = _make_guard()
        guard.record_buy("XOM", 100, 90.0, date(2025, 1, 1))
        assert guard.get_realized_gains("XOM") == 0.0

    def test_realized_gains_unknown_symbol(self):
        """Unknown symbol returns zero."""
        guard = _make_guard()
        assert guard.get_realized_gains("NONEXISTENT") == 0.0


class TestUnrealizedPnL:
    def test_unrealized_pnl_computation(self):
        """Unrealized P&L computed from current price vs cost basis."""
        guard = _make_guard()
        guard.record_buy("NFLX", 100, 400.0, date(2025, 1, 1))
        guard.record_buy("NFLX", 50, 420.0, date(2025, 1, 10))

        # Current price is $450
        pnl = guard.get_unrealized_pnl("NFLX", 450.0)
        # Lot 1: (450 - 400) * 100 = 5000
        # Lot 2: (450 - 420) * 50  = 1500
        assert pnl == 6500.0

    def test_unrealized_pnl_excludes_sold_lots(self):
        """Sold lots are excluded from unrealized P&L."""
        guard = _make_guard()
        guard.record_buy("DIS", 100, 100.0, date(2025, 1, 1))
        guard.record_buy("DIS", 100, 110.0, date(2025, 1, 5))
        guard.record_sell("DIS", 100, 120.0, date(2025, 2, 1))

        # Only the second lot (100 shares at $110) is still open
        pnl = guard.get_unrealized_pnl("DIS", 130.0)
        assert pnl == (130.0 - 110.0) * 100  # 2000.0


class TestWashSaleCheckForSell:
    def test_wash_sale_check_for_sell_with_recent_buys(self):
        """Selling warns about wash sale risk when there are recent buys."""
        guard = _make_guard()
        guard.record_buy("INTC", 100, 50.0, date(2025, 1, 1))
        guard.record_buy("INTC", 50, 48.0, date(2025, 1, 20))

        check = guard.check_wash_sale("INTC", "sell", date(2025, 1, 25))
        assert check.is_blocked is False
        assert "Warning" in check.reason
        assert "buy(s)" in check.reason

    def test_wash_sale_check_for_sell_no_recent_buys(self):
        """Selling with no recent buys just notes the future risk window."""
        guard = _make_guard()
        guard.record_buy("INTC", 100, 50.0, date(2024, 6, 1))

        check = guard.check_wash_sale("INTC", "sell", date(2025, 2, 1))
        assert check.is_blocked is False
        assert "No recent buys" in check.reason
        assert "30 days" in check.reason


class TestHandleSignal:
    @pytest.mark.asyncio
    async def test_handle_signal_records_buy(self):
        """ORDER_FILLED with side=buy creates a lot."""
        bus = SignalBus()
        guard = WashSaleGuard(bus)

        signal = _make_signal("AAPL", "buy", 100, 150.0, "2025-01-15")
        await guard.handle_signal(signal)

        lots = guard.get_tax_lots("AAPL")
        assert len(lots) == 1
        assert lots[0].cost_basis == 150.0

    @pytest.mark.asyncio
    async def test_handle_signal_records_sell(self):
        """ORDER_FILLED with side=sell records the sale."""
        bus = SignalBus()
        guard = WashSaleGuard(bus)

        # First buy, then sell
        buy_signal = _make_signal("AAPL", "buy", 100, 150.0, "2025-01-15")
        await guard.handle_signal(buy_signal)

        sell_signal = _make_signal("AAPL", "sell", 100, 160.0, "2025-02-15")
        await guard.handle_signal(sell_signal)

        lots = guard.get_tax_lots("AAPL")
        sold = [l for l in lots if l.sold_date is not None]
        assert len(sold) == 1
        assert sold[0].sold_price == 160.0

    @pytest.mark.asyncio
    async def test_handle_signal_wash_sale_emits_block(self):
        """A buy that triggers wash sale emits WASH_SALE_BLOCK signal."""
        bus = SignalBus()
        guard = WashSaleGuard(bus)
        guard.register()

        captured: list[Signal] = []

        async def capture(s: Signal) -> None:
            captured.append(s)

        bus.subscribe(SignalTypes.WASH_SALE_BLOCK, capture)

        task = asyncio.create_task(bus.run())

        # Buy, sell at loss, then buy again within window
        await guard.handle_signal(
            _make_signal("AAPL", "buy", 100, 150.0, "2025-01-15")
        )
        await guard.handle_signal(
            _make_signal("AAPL", "sell", 100, 120.0, "2025-02-01")
        )
        await guard.handle_signal(
            _make_signal("AAPL", "buy", 100, 125.0, "2025-02-10")
        )

        await asyncio.sleep(0.05)
        task.cancel()

        assert len(captured) == 1
        assert captured[0].payload["symbol"] == "AAPL"
        assert captured[0].payload["disallowed_loss"] == 3000.0  # (150-120)*100


class TestToDict:
    def test_to_dict_includes_wash_sale_data(self):
        guard = _make_guard()
        guard.record_buy("AAPL", 100, 150.0, date(2025, 1, 15))

        d = guard.to_dict()
        assert d["agent_id"] == "wash_sale_guard"
        assert d["squadron"] == "foxtrot"
        assert d["wash_sale_window_days"] == 30
        assert "AAPL" in d["tracked_symbols"]
        assert d["total_lots"] == 1
