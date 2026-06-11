"""INDIA squadron (geospatial physical-alpha) tests.

Verifies MaritimeAnalyst computes chokepoint-congestion and floating-storage alpha
from AIS snapshots, and GeoRiskMapper flags quakes near energy assets. Requires the
compiled Rust core (cortex_scanner); skipped cleanly if it is not installed.
"""

import time
import pytest

pytest.importorskip("cortex_scanner")  # geo math lives in the Rust core

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.india.maritime_analyst import MaritimeAnalyst
from cortex.squadrons.india.geo_risk_mapper import GeoRiskMapper


def _capture(agent):
    """Replace agent.emit with a recorder. Returns the captured list."""
    emitted: list[tuple[str, dict]] = []

    async def rec(signal_type, payload, priority=None):
        emitted.append((signal_type, payload))

    agent.emit = rec  # shadow the bound method
    return emitted


def _batch_signal(vessels):
    return Signal(
        signal_id="t", source_agent="feeds", source_squadron="feeds",
        signal_type=SignalTypes.GEO_VESSEL_BATCH, payload={"vessels": vessels},
        priority=SignalPriority.LOW,
    )


async def test_chokepoint_congestion_alpha():
    bus = SignalBus()
    agent = MaritimeAnalyst(bus)
    emitted = _capture(agent)

    # 5 slow tankers sitting in the Strait of Hormuz geofence.
    vessels = [
        {"mmsi": 200000 + i, "lat": 26.6, "lon": 56.3, "speed_knots": 1.0,
         "ship_type": 80, "is_tanker": True, "draught": 0.0}
        for i in range(5)
    ]
    await agent.handle_signal(_batch_signal(vessels))

    types = [t for t, _ in emitted]
    assert SignalTypes.GEO_CHOKEPOINT_CONGESTION in types
    assert SignalTypes.GEO_PHYSICAL_ALPHA in types

    alpha = [p for t, p in emitted if t == SignalTypes.GEO_PHYSICAL_ALPHA
             and p["signal"] == "chokepoint_congestion"][0]
    syms = {tk["symbol"]: tk["direction"] for tk in alpha["tickers"]}
    assert syms.get("CL") == "long"           # congestion = crude supply premium
    assert alpha["chokepoint"] == "Strait of Hormuz"
    assert 0.0 < alpha["confidence"] <= 1.0


async def test_floating_storage_alpha():
    bus = SignalBus()
    agent = MaritimeAnalyst(bus)
    emitted = _capture(agent)

    # Seed 60 tankers as already-idle for >7 days, drifting in open ocean (no
    # chokepoint) so ONLY the floating-storage path fires.
    now = time.time()
    vessels = []
    for i in range(60):
        mmsi = 300000 + i
        agent._idle_since[mmsi] = now - 200 * 3600  # idle 200h
        vessels.append({"mmsi": mmsi, "lat": 0.0, "lon": -140.0, "speed_knots": 0.1,
                        "ship_type": 80, "is_tanker": True, "draught": 0.0})

    await agent.handle_signal(_batch_signal(vessels))

    fs = [p for t, p in emitted if t == SignalTypes.GEO_FLOATING_STORAGE][0]
    assert fs["count"] == 60 and fs["index_score"] >= 50.0

    alpha = [p for t, p in emitted if t == SignalTypes.GEO_PHYSICAL_ALPHA
             and p["signal"] == "floating_storage"][0]
    syms = {tk["symbol"]: tk["direction"] for tk in alpha["tickers"]}
    assert syms.get("CL") == "short"          # rising storage = bearish crude
    assert syms.get("FRO") == "long"          # bullish tanker rates


async def test_no_alpha_when_quiet():
    """A handful of fast-moving cargo ships nowhere near a chokepoint = no alpha."""
    bus = SignalBus()
    agent = MaritimeAnalyst(bus)
    emitted = _capture(agent)
    vessels = [{"mmsi": 1, "lat": 10.0, "lon": -50.0, "speed_knots": 14.0,
                "ship_type": 70, "is_tanker": False, "draught": 0.0}]
    await agent.handle_signal(_batch_signal(vessels))
    assert SignalTypes.GEO_PHYSICAL_ALPHA not in [t for t, _ in emitted]


async def test_seismic_proximity_to_energy_asset():
    bus = SignalBus()
    agent = GeoRiskMapper(bus)
    emitted = _capture(agent)

    # M6.0 quake right at the US Gulf Coast refining hub.
    ev = Signal(
        signal_id="q", source_agent="feeds", source_squadron="feeds",
        signal_type=SignalTypes.GEO_SEISMIC,
        payload={"magnitude": 6.0, "lat": 29.76, "lon": -95.36,
                 "label": "near Houston", "id": "q1"},
        priority=SignalPriority.NORMAL,
    )
    await agent.handle_signal(ev)

    prox = [p for t, p in emitted if t == SignalTypes.GEO_SEISMIC_PROXIMITY]
    assert prox, "expected a seismic-proximity alert"
    syms = {tk["symbol"] for tk in prox[0]["tickers"]}
    assert {"XOM", "VLO", "CL"} & syms
    assert prox[0]["severity"] > 0.0


async def test_seismic_too_weak_or_far_is_ignored():
    bus = SignalBus()
    agent = GeoRiskMapper(bus)
    emitted = _capture(agent)
    # M3 (too weak) and a strong quake mid-Pacific (too far) — neither alerts.
    for payload in (
        {"magnitude": 3.0, "lat": 29.76, "lon": -95.36, "id": "a"},
        {"magnitude": 6.5, "lat": 0.0, "lon": -150.0, "id": "b"},
    ):
        sig = Signal(signal_id=payload["id"], source_agent="feeds",
                     source_squadron="feeds", signal_type=SignalTypes.GEO_SEISMIC,
                     payload=payload, priority=SignalPriority.NORMAL)
        await agent.handle_signal(sig)
    assert not emitted
