"""GeoRiskContext + RiskGuardian geo-fusion tests.

Proves the geo caution layer is a SAFE, one-directional tightener:
  - No geo signal => sizing/approval is byte-for-byte unchanged (regression guard).
  - A geo-caution signal shrinks a symbol's size (never grows it) and never
    approves an order the base checks reject.
  - TTL expiry: stale geo caution stops affecting sizing.
  - Kill switch / hard risk rejections still win regardless of geo state.
"""

import time

import pytest

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.echo.geo_risk_context import GeoRiskContext
from cortex.squadrons.echo.risk_guardian import RiskGuardian
from cortex.squadrons.echo.risk_checks import PreTradeCheck
from cortex.squadrons.echo.position_sizer import PositionSizer
from cortex.squadrons.echo.drawdown_shield import DrawdownShield


# ── helpers ───────────────────────────────────────────────────────────────

def make_guardian(
    is_halted: bool = False,
    geo_context: GeoRiskContext | None = None,
) -> RiskGuardian:
    bus = SignalBus()
    return RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: is_halted,
        pre_trade=PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50),
        position_sizer=PositionSizer(max_position_pct=5.0, fixed_fractional_pct=1.0,
                                     max_single_loss_usd=500.0),
        drawdown_shield=DrawdownShield(),
        geo_context=geo_context,
    )


def _physical_alpha(symbol: str, severity: float, direction: str = "short") -> dict:
    """An INDIA GEO_PHYSICAL_ALPHA-shaped payload for one symbol."""
    return {
        "signal": "floating_storage",
        "score": severity * 100.0,
        "confidence": severity,
        "tickers": [{"symbol": symbol, "direction": direction,
                     "rationale": "rising crude floating storage"}],
        "source": "maritime_ais",
        "ts": time.time(),
    }


def _evaluate(guardian: RiskGuardian, symbol: str = "CL", **over):
    args = dict(
        symbol=symbol, asset_class="equity",
        entry_price=10.0, stop_loss_price=9.0, side="buy",
        nav=500_000.0, position_count=1, daily_trade_count=1,
    )
    args.update(over)
    return guardian.evaluate(**args)


# ── GeoRiskContext unit behavior ────────────────────────────────────────────

def test_context_default_safe_no_signal():
    ctx = GeoRiskContext()
    assert ctx.caution_for("CL") == 0.0
    assert ctx.reasons_for("CL") == []
    assert ctx.size_multiplier("CL") == 1.0
    assert ctx.should_veto("CL") is False


def test_context_multiplier_only_shrinks():
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.8))
    mult = ctx.size_multiplier("CL")
    assert 0.0 < mult < 1.0  # tightens, never grows, never zeroes
    assert ctx.caution_for("CL") == pytest.approx(0.8, abs=1e-6)
    assert ctx.reasons_for("CL")  # has a human-readable reason


def test_context_higher_caution_shrinks_more():
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.3))
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("XLE", 0.9))
    assert ctx.size_multiplier("XLE") < ctx.size_multiplier("CL") < 1.0


def test_context_max_caution_keeps_position_alive():
    """Even at caution 1.0 the multiplier stays strictly positive — geo tightens,
    it must not zero-out the position (that's the kill switch's job)."""
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 1.0))
    assert ctx.size_multiplier("CL") > 0.0


def test_context_veto_only_at_extreme():
    ctx = GeoRiskContext(veto_threshold=0.9)
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.5))
    assert ctx.should_veto("CL") is False
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.95))
    assert ctx.should_veto("CL") is True


def test_context_ignores_non_geo_and_malformed():
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.ENTRY_SIGNAL, _physical_alpha("CL", 0.9))  # wrong type
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, {"tickers": []})        # empty
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, {"tickers": [{"foo": 1}]})  # no symbol
    assert ctx.tracked_symbols == 0
    assert ctx.caution_for("CL") == 0.0


def test_context_severity_from_score_when_no_severity():
    ctx = GeoRiskContext()
    payload = {"signal": "chokepoint_congestion", "score": 60.0,
               "tickers": [{"symbol": "CL", "direction": "long", "rationale": "x"}]}
    ctx.ingest_signal(SignalTypes.GEO_CHOKEPOINT_CONGESTION, payload)
    assert ctx.caution_for("CL") == pytest.approx(0.6, abs=1e-6)


def test_context_ttl_expiry():
    ctx = GeoRiskContext(ttl_seconds=0.05)
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.8))
    assert ctx.caution_for("CL") > 0.0
    time.sleep(0.06)
    assert ctx.caution_for("CL") == 0.0
    assert ctx.size_multiplier("CL") == 1.0
    assert ctx.should_veto("CL") is False


def test_context_memory_bound():
    ctx = GeoRiskContext(max_symbols=10)
    for i in range(50):
        ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha(f"SYM{i}", 0.5))
    assert ctx.tracked_symbols <= 10


def test_context_seismic_severity_field():
    ctx = GeoRiskContext()
    payload = {"signal": "seismic_proximity", "severity": 0.7,
               "tickers": [{"symbol": "XOM", "direction": "long", "rationale": "quake"}]}
    ctx.ingest_signal(SignalTypes.GEO_SEISMIC_PROXIMITY, payload)
    assert ctx.caution_for("XOM") == pytest.approx(0.7, abs=1e-6)


# ── RiskGuardian integration ────────────────────────────────────────────────

def test_guardian_no_geo_is_unchanged():
    """Regression guard: with no geo signal, the decision matches a guardian that
    has no geo context wired at all — byte-for-byte identical sizing."""
    plain = make_guardian()  # default GeoRiskContext, empty
    d1 = _evaluate(plain, symbol="AAPL", entry_price=150.0, stop_loss_price=145.0)

    bare_bus = SignalBus()
    bare = RiskGuardian(bus=bare_bus, kill_switch_check=lambda: False,
                        pre_trade=PreTradeCheck(max_position_pct=5.0, max_concurrent=15,
                                                max_daily_trades=50),
                        position_sizer=PositionSizer(max_position_pct=5.0,
                                                     fixed_fractional_pct=1.0,
                                                     max_single_loss_usd=500.0),
                        drawdown_shield=DrawdownShield())
    d2 = bare.evaluate(symbol="AAPL", asset_class="equity", entry_price=150.0,
                       stop_loss_price=145.0, side="buy", nav=500_000.0,
                       position_count=1, daily_trade_count=1)

    assert d1.approved and d2.approved
    assert d1.sizing.recommended_quantity == d2.sizing.recommended_quantity
    assert d1.geo_caution == 0.0
    assert d1.geo_veto is False


def test_guardian_geo_caution_shrinks_size():
    ctx = GeoRiskContext()
    guardian = make_guardian(geo_context=ctx)

    base = _evaluate(guardian, symbol="CL")
    base_qty = base.sizing.recommended_quantity
    assert base.approved and base_qty > 1  # need room to shrink

    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.8))
    geo = _evaluate(guardian, symbol="CL")

    assert geo.approved is True
    assert geo.geo_caution == pytest.approx(0.8, abs=1e-6)
    assert geo.sizing.recommended_quantity <= base_qty   # only shrinks
    assert geo.sizing.recommended_quantity < base_qty     # actually shrank
    assert geo.geo_reasons  # reasons surfaced for review


def test_guardian_geo_never_grows_size():
    """Sanity: across a range of cautions, geo size is always <= the base size."""
    ctx = GeoRiskContext()
    guardian = make_guardian(geo_context=ctx)
    base_qty = _evaluate(guardian, symbol="CL").sizing.recommended_quantity
    for sev in (0.1, 0.4, 0.7, 1.0):
        ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", sev))
        q = _evaluate(guardian, symbol="CL").sizing.recommended_quantity
        assert q <= base_qty


def test_guardian_geo_does_not_approve_rejected_order():
    """A geo signal must NEVER rescue an order the base checks reject."""
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.95))
    guardian = make_guardian(geo_context=ctx)

    # Drawdown over the halt threshold => pre-trade rejects regardless of geo.
    d = _evaluate(guardian, symbol="CL", daily_drawdown_pct=99.0)
    assert d.approved is False


def test_guardian_kill_switch_wins_over_geo():
    ctx = GeoRiskContext()
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.95))
    guardian = make_guardian(is_halted=True, geo_context=ctx)
    d = _evaluate(guardian, symbol="CL")
    assert d.approved is False
    assert any("HALTED" in r for r in d.rejections)


def test_guardian_geo_ttl_expiry_restores_size():
    ctx = GeoRiskContext(ttl_seconds=0.05)
    guardian = make_guardian(geo_context=ctx)
    base_qty = _evaluate(guardian, symbol="CL").sizing.recommended_quantity

    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.8))
    shrunk = _evaluate(guardian, symbol="CL").sizing.recommended_quantity
    assert shrunk < base_qty

    time.sleep(0.06)  # let the caution expire
    restored = _evaluate(guardian, symbol="CL")
    assert restored.geo_caution == 0.0
    assert restored.sizing.recommended_quantity == base_qty


async def test_guardian_ingests_geo_signal_from_bus():
    """The RiskGuardian subscribes to INDIA geo signals and folds them into its
    caution map without importing the INDIA squadron."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    guardian.register()

    sig = Signal(
        signal_id="geo1", source_agent="maritime_analyst", source_squadron="india",
        signal_type=SignalTypes.GEO_PHYSICAL_ALPHA,
        payload=_physical_alpha("CL", 0.8), priority=SignalPriority.NORMAL,
    )
    await guardian.handle_signal(sig)
    assert guardian.geo_context.caution_for("CL") == pytest.approx(0.8, abs=1e-6)


def test_guardian_geo_veto_flag_does_not_block():
    """An extreme-caution veto FLAGS the decision but still approves a valid order
    (it tightens; it doesn't reject). Hard checks remain the only rejecters."""
    ctx = GeoRiskContext(veto_threshold=0.9)
    ctx.ingest_signal(SignalTypes.GEO_PHYSICAL_ALPHA, _physical_alpha("CL", 0.95))
    guardian = make_guardian(geo_context=ctx)
    d = _evaluate(guardian, symbol="CL")
    assert d.approved is True
    assert d.geo_veto is True
    assert d.sizing.recommended_quantity >= 1
