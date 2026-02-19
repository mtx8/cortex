"""Comprehensive tests for the FOXTROT Harvest Bot.

All dates are deterministic using datetime.date.
Follows existing CORTEX test patterns (pytest + pytest-asyncio).
"""

from datetime import date

import pytest

from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.foxtrot.harvest_bot import (
    HarvestBot,
    HarvestConfig,
    HarvestOpportunity,
)
from cortex.squadrons.foxtrot.wash_sale_guard import WashSaleGuard


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_bot(
    config: HarvestConfig | None = None,
    guard: WashSaleGuard | None = None,
) -> tuple[HarvestBot, WashSaleGuard]:
    """Create a HarvestBot with its WashSaleGuard dependency."""
    bus = SignalBus()
    wsg = guard or WashSaleGuard(bus)
    bot = HarvestBot(bus, wsg, config=config)
    return bot, wsg


# A fixed reference date for all tests.
REF_DATE = date(2025, 6, 15)


def _loss_position(
    symbol: str = "AAPL",
    quantity: int = 100,
    cost_basis: float = 150.0,
    current_price: float = 120.0,
    acquired_date: str = "2025-01-15",
) -> dict[str, dict]:
    return {
        symbol: {
            "quantity": quantity,
            "cost_basis": cost_basis,
            "current_price": current_price,
            "acquired_date": acquired_date,
        }
    }


def _gain_position(
    symbol: str = "MSFT",
    quantity: int = 100,
    cost_basis: float = 300.0,
    current_price: float = 350.0,
    acquired_date: str = "2025-01-15",
) -> dict[str, dict]:
    return {
        symbol: {
            "quantity": quantity,
            "cost_basis": cost_basis,
            "current_price": current_price,
            "acquired_date": acquired_date,
        }
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


class TestScanFindsLosses:
    def test_scan_finds_losses(self):
        """Positions with unrealized losses appear as harvest opportunities."""
        bot, _ = _make_bot()
        positions = _loss_position("AAPL", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 1
        opp = opps[0]
        assert opp.symbol == "AAPL"
        assert opp.unrealized_loss == (150.0 - 120.0) * 100  # 3000.0
        assert opp.quantity == 100
        assert opp.cost_basis == 150.0
        assert opp.current_price == 120.0


class TestScanIgnoresGains:
    def test_scan_ignores_gains(self):
        """Positions with unrealized gains are excluded."""
        bot, _ = _make_bot()
        positions = _gain_position("MSFT", 100, 300.0, 350.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 0


class TestMinLossThreshold:
    def test_min_loss_threshold(self):
        """Losses below the $100 minimum are excluded."""
        bot, _ = _make_bot()
        # Loss = (100 - 99) * 10 = $10 — below the $100 threshold
        positions = _loss_position("TINY", 10, 100.0, 99.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 0

    def test_loss_exactly_at_threshold(self):
        """A loss of exactly $100 is included."""
        bot, _ = _make_bot()
        # Loss = (200 - 199) * 100 = $100 — at the threshold
        positions = _loss_position("EDGE", 100, 200.0, 199.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        # loss_pct = 1 / 200 = 0.005, below 5 % -> excluded by pct filter
        assert len(opps) == 0


class TestMinLossPctThreshold:
    def test_min_loss_pct_threshold(self):
        """Losses below the 5% minimum percentage are excluded."""
        bot, _ = _make_bot()
        # Loss pct = (200 - 195) / 200 = 2.5 % — below 5 %
        # Dollar loss = 5 * 100 = $500 — above $100 threshold
        positions = _loss_position("SMALL", 100, 200.0, 195.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 0

    def test_loss_above_pct_threshold(self):
        """Losses at or above 5% are included (assuming dollar threshold met)."""
        bot, _ = _make_bot()
        # Loss pct = (200 - 188) / 200 = 6 % — above 5 %
        # Dollar loss = 12 * 100 = $1200 — above $100
        positions = _loss_position("OVER", 100, 200.0, 188.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 1
        assert opps[0].loss_pct == pytest.approx(0.06, abs=1e-6)


class TestWashSaleSafeCheck:
    def test_wash_sale_safe_check(self):
        """Blocked symbols are flagged as wash_sale_safe=False."""
        bot, wsg = _make_bot()

        # Create a loss sale in the wash sale guard so AAPL is blocked.
        wsg.record_buy("AAPL", 50, 200.0, date(2025, 5, 1))
        wsg.record_sell("AAPL", 50, 150.0, date(2025, 6, 1))
        # AAPL sold at loss on June 1 — blocked within 30-day window of REF_DATE (June 15)

        positions = _loss_position("AAPL", 100, 180.0, 140.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 1
        assert opps[0].wash_sale_safe is False

    def test_unblocked_symbol_is_safe(self):
        """Symbols without recent loss sales are wash_sale_safe=True."""
        bot, _ = _make_bot()
        positions = _loss_position("GOOG", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 1
        assert opps[0].wash_sale_safe is True


class TestHoldingPeriodCalculation:
    def test_holding_period_calculation(self):
        """Holding period is correctly computed as days since acquired_date."""
        bot, _ = _make_bot()
        # acquired 2025-01-15, as_of 2025-06-15 -> 151 days
        positions = _loss_position("AAPL", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        expected_days = (REF_DATE - date(2025, 1, 15)).days  # 151
        assert opps[0].holding_period_days == expected_days


class TestLongTermClassification:
    def test_long_term_classification(self):
        """>365 days holding period is classified as long term."""
        bot, _ = _make_bot()
        # acquired 2024-01-01, as_of 2025-06-15 -> 531 days (> 365)
        positions = _loss_position("OLD", 100, 150.0, 120.0, "2024-01-01")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert opps[0].is_long_term is True
        assert opps[0].holding_period_days > 365

    def test_short_term_classification(self):
        """<=365 days holding period is classified as short term."""
        bot, _ = _make_bot()
        # acquired 2025-01-15, as_of 2025-06-15 -> 151 days
        positions = _loss_position("NEW", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert opps[0].is_long_term is False
        assert opps[0].holding_period_days <= 365


class TestTaxSavingsEstimationShortTerm:
    def test_tax_savings_estimation_short_term(self):
        """Short-term savings = unrealized_loss * (0.37 + 0.05)."""
        bot, _ = _make_bot()
        # Loss = (150 - 120) * 100 = $3000, short-term
        positions = _loss_position("AAPL", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        expected_savings = 3000.0 * (0.37 + 0.05)  # 1260.0
        assert opps[0].estimated_tax_savings == pytest.approx(expected_savings)
        assert opps[0].is_long_term is False


class TestTaxSavingsEstimationLongTerm:
    def test_tax_savings_estimation_long_term(self):
        """Long-term savings = unrealized_loss * (0.20 + 0.05)."""
        bot, _ = _make_bot()
        # Loss = (150 - 120) * 100 = $3000, long-term (acquired > 365 days ago)
        positions = _loss_position("OLD", 100, 150.0, 120.0, "2024-01-01")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        expected_savings = 3000.0 * (0.20 + 0.05)  # 750.0
        assert opps[0].estimated_tax_savings == pytest.approx(expected_savings)
        assert opps[0].is_long_term is True


class TestPriorityScoring:
    def test_priority_scoring(self):
        """Larger losses rank higher than smaller losses."""
        bot, _ = _make_bot()
        positions = {
            "BIG_LOSS": {
                "quantity": 100,
                "cost_basis": 200.0,
                "current_price": 100.0,  # loss = $10,000
                "acquired_date": "2025-03-15",
            },
            "SMALL_LOSS": {
                "quantity": 100,
                "cost_basis": 150.0,
                "current_price": 130.0,  # loss = $2,000
                "acquired_date": "2025-03-15",
            },
        }

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 2
        assert opps[0].symbol == "BIG_LOSS"
        assert opps[1].symbol == "SMALL_LOSS"
        assert opps[0].priority_score > opps[1].priority_score

    def test_shorter_holding_boosts_priority(self):
        """With equal dollar loss, shorter holding period gives higher priority."""
        bot, _ = _make_bot()
        positions = {
            "RECENT": {
                "quantity": 100,
                "cost_basis": 200.0,
                "current_price": 150.0,  # loss = $5,000
                "acquired_date": "2025-06-01",  # 14 days holding
            },
            "OLDER": {
                "quantity": 100,
                "cost_basis": 200.0,
                "current_price": 150.0,  # loss = $5,000
                "acquired_date": "2025-01-01",  # 165 days holding
            },
        }

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        assert len(opps) == 2
        # RECENT should have higher priority (same loss, shorter holding)
        recent = next(o for o in opps if o.symbol == "RECENT")
        older = next(o for o in opps if o.symbol == "OLDER")
        assert recent.priority_score > older.priority_score


class TestTopOpportunitiesLimit:
    def test_top_opportunities_limit(self):
        """get_top_opportunities returns at most N results."""
        bot, _ = _make_bot()
        positions = {}
        for i in range(10):
            positions[f"SYM{i}"] = {
                "quantity": 100,
                "cost_basis": 200.0,
                "current_price": 100.0,  # big loss for each
                "acquired_date": "2025-01-15",
            }

        opps = bot.get_top_opportunities(positions, count=3, as_of=REF_DATE)

        assert len(opps) == 3

    def test_top_opportunities_fewer_than_count(self):
        """Returns all when fewer opportunities than count requested."""
        bot, _ = _make_bot()
        positions = _loss_position("ONLY", 100, 200.0, 100.0, "2025-01-15")

        opps = bot.get_top_opportunities(positions, count=5, as_of=REF_DATE)

        assert len(opps) == 1


class TestAnnualSavingsAggregation:
    def test_annual_savings_aggregation(self):
        """Totals across short-term and long-term opportunities."""
        bot, _ = _make_bot()

        # Create two opportunities manually.
        short_term_opp = HarvestOpportunity(
            symbol="SHORT",
            current_price=120.0,
            cost_basis=150.0,
            unrealized_loss=3000.0,
            quantity=100,
            loss_pct=0.20,
            holding_period_days=100,
            is_long_term=False,
            wash_sale_safe=True,
            estimated_tax_savings=1260.0,  # 3000 * 0.42
            priority_score=30.0,
        )
        long_term_opp = HarvestOpportunity(
            symbol="LONG",
            current_price=80.0,
            cost_basis=100.0,
            unrealized_loss=2000.0,
            quantity=100,
            loss_pct=0.20,
            holding_period_days=400,
            is_long_term=True,
            wash_sale_safe=True,
            estimated_tax_savings=500.0,  # 2000 * 0.25
            priority_score=5.0,
        )

        result = bot.estimate_annual_savings([short_term_opp, long_term_opp])

        assert result["short_term_savings"] == 1260.0
        assert result["long_term_savings"] == 500.0
        assert result["total_savings"] == 1760.0

    def test_annual_savings_empty_list(self):
        """Empty opportunity list yields zero savings."""
        bot, _ = _make_bot()
        result = bot.estimate_annual_savings([])

        assert result["total_savings"] == 0.0
        assert result["short_term_savings"] == 0.0
        assert result["long_term_savings"] == 0.0


class TestEmptyPortfolio:
    def test_empty_portfolio(self):
        """No positions yields no opportunities."""
        bot, _ = _make_bot()

        opps = bot.scan_portfolio({}, as_of=REF_DATE)

        assert opps == []


class TestHandleSignal:
    @pytest.mark.asyncio
    async def test_handle_signal_is_noop(self):
        """handle_signal does nothing (bot runs on schedule)."""
        from cortex.orchestrator.bus import Signal, SignalPriority

        bot, _ = _make_bot()
        signal = Signal(
            signal_id="test_1",
            source_agent="test",
            source_squadron="alpha",
            signal_type="alpha.market_signal",
            payload={},
            priority=SignalPriority.NORMAL,
        )
        # Should not raise
        await bot.handle_signal(signal)


class TestToDict:
    def test_to_dict_includes_config(self):
        """to_dict output contains agent metadata and config."""
        bot, _ = _make_bot()

        d = bot.to_dict()

        assert d["agent_id"] == "harvest_bot"
        assert d["squadron"] == "foxtrot"
        assert d["status"] == "idle"
        assert "config" in d
        assert d["config"]["min_loss_usd"] == 100.0
        assert d["config"]["min_loss_pct"] == 0.05
        assert d["config"]["tax_rate_short"] == 0.37
        assert d["config"]["tax_rate_long"] == 0.20
        assert d["config"]["state_tax_rate"] == 0.05
        assert d["config"]["max_harvest_per_day"] == 5
        assert d["config"]["respect_wash_sales"] is True


class TestEmitOpportunities:
    @pytest.mark.asyncio
    async def test_emit_opportunities_publishes_signals(self):
        """emit_opportunities emits TAX_HARVEST_SIGNAL for each opportunity."""
        import asyncio
        from cortex.orchestrator.bus import SignalPriority

        bus = SignalBus()
        wsg = WashSaleGuard(bus)
        bot = HarvestBot(bus, wsg)

        captured: list = []

        async def capture(s) -> None:
            captured.append(s)

        bus.subscribe(SignalTypes.TAX_HARVEST_SIGNAL, capture)
        task = asyncio.create_task(bus.run())

        opp = HarvestOpportunity(
            symbol="AAPL",
            current_price=120.0,
            cost_basis=150.0,
            unrealized_loss=3000.0,
            quantity=100,
            loss_pct=0.20,
            holding_period_days=100,
            is_long_term=False,
            wash_sale_safe=True,
            estimated_tax_savings=1260.0,
            priority_score=30.0,
        )
        await bot.emit_opportunities([opp])
        await asyncio.sleep(0.05)
        task.cancel()

        assert len(captured) == 1
        assert captured[0].payload["symbol"] == "AAPL"
        assert captured[0].payload["unrealized_loss"] == 3000.0


class TestCustomConfig:
    def test_custom_thresholds(self):
        """Custom config thresholds are respected."""
        config = HarvestConfig(
            min_loss_usd=500.0,
            min_loss_pct=0.10,
        )
        bot, _ = _make_bot(config=config)

        # Loss = (150 - 140) * 100 = $1000 (above $500)
        # Loss pct = 10/150 = 6.67 % (below 10 %)
        positions = _loss_position("AAPL", 100, 150.0, 140.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        # Excluded by pct threshold
        assert len(opps) == 0

    def test_custom_tax_rates(self):
        """Custom tax rates affect estimated savings."""
        config = HarvestConfig(
            tax_rate_short=0.32,
            tax_rate_long=0.15,
            state_tax_rate=0.10,
        )
        bot, _ = _make_bot(config=config)

        # Short-term loss = $3000
        positions = _loss_position("AAPL", 100, 150.0, 120.0, "2025-01-15")

        opps = bot.scan_portfolio(positions, as_of=REF_DATE)

        expected_savings = 3000.0 * (0.32 + 0.10)  # 1260.0
        assert opps[0].estimated_tax_savings == pytest.approx(expected_savings)
