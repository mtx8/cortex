"""RatesAnalyst (JULIETT macro/fixed-income) signal tests."""

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.juliett.rates_analyst import RatesAnalyst


def _capture(agent):
    emitted: list[tuple[str, dict]] = []

    async def rec(signal_type, payload, priority=None):
        emitted.append((signal_type, payload))

    agent.emit = rec
    return emitted


def _sig(payload):
    return Signal(signal_id="r", source_agent="feeds", source_squadron="feeds",
                  signal_type=SignalTypes.MACRO_RATES, payload=payload,
                  priority=SignalPriority.LOW)


async def test_inversion_emits_risk_off():
    agent = RatesAnalyst(SignalBus())
    emitted = _capture(agent)
    # short (bills) > long (bonds) => negative long-minus-short spread
    await agent.handle_signal(_sig({"date": "2026-05-31", "short_pct": 5.0,
                                    "long_pct": 4.0, "spread_bps": -100.0}))
    types = [t for t, _ in emitted]
    assert SignalTypes.YIELD_CURVE_INVERSION in types
    inv = [p for t, p in emitted if t == SignalTypes.YIELD_CURVE_INVERSION][0]
    syms = {tk["symbol"]: tk["direction"] for tk in inv["tickers"]}
    assert syms.get("TLT") == "long" and syms.get("XLF") == "short"


async def test_no_inversion_when_positive_spread():
    agent = RatesAnalyst(SignalBus())
    emitted = _capture(agent)
    await agent.handle_signal(_sig({"short_pct": 3.0, "long_pct": 4.0, "spread_bps": 100.0}))
    assert SignalTypes.YIELD_CURVE_INVERSION not in [t for t, _ in emitted]


async def test_regime_levels():
    agent = RatesAnalyst(SignalBus())
    emitted = _capture(agent)
    await agent.handle_signal(_sig({"long_pct": 5.0, "spread_bps": 50.0}))
    regimes = [p["regime"] for t, p in emitted if t == SignalTypes.RATES_REGIME]
    assert regimes and regimes[-1] == "restrictive"

    agent2 = RatesAnalyst(SignalBus())
    em2 = _capture(agent2)
    await agent2.handle_signal(_sig({"long_pct": 2.0, "spread_bps": 30.0}))
    assert [p["regime"] for t, p in em2 if t == SignalTypes.RATES_REGIME][-1] == "accommodative"


async def test_regime_emits_only_on_change():
    agent = RatesAnalyst(SignalBus())
    emitted = _capture(agent)
    payload = {"long_pct": 5.0, "spread_bps": 40.0}
    await agent.handle_signal(_sig(payload))
    await agent.handle_signal(_sig(payload))  # same regime -> no second emit
    regime_emits = [t for t, _ in emitted if t == SignalTypes.RATES_REGIME]
    assert len(regime_emits) == 1
