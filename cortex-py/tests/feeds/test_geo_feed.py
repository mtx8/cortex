"""geo_feed vessel-dict enrichment tests (real ship-type classification)."""

import pytest

pytest.importorskip("cortex_scanner")

import cortex_scanner as cs
from cortex.feeds.geo_feed import _vessel_to_dict


def test_vessel_dict_without_metadata_is_position_only():
    # Locations endpoint omits ship type -> type 0 -> not a tanker.
    v = cs.Vessel(230111, 60.1, 24.9, 12.0)  # mmsi, lat, lon, speed
    d = _vessel_to_dict(v)
    assert d["mmsi"] == 230111 and d["ship_type"] == 0
    assert d["is_tanker"] is False and d["category"] == "unknown"


def test_vessel_dict_enriched_with_metadata_detects_tanker():
    v = cs.Vessel(230111, 60.1, 24.9, 0.3)
    meta = {230111: {"ship_type": 80, "draught_m": 9.4, "name": "CRUDE TRADER"}}
    d = _vessel_to_dict(v, meta)
    assert d["ship_type"] == 80
    assert d["is_tanker"] is True
    assert d["category"] == "tanker"
    assert abs(d["draught"] - 9.4) < 1e-9
    assert d["name"] == "CRUDE TRADER"


def test_enrichment_ignores_missing_mmsi():
    v = cs.Vessel(999, 0.0, 0.0, 5.0)
    d = _vessel_to_dict(v, {230111: {"ship_type": 80}})  # different mmsi
    assert d["is_tanker"] is False  # unchanged, no metadata for 999
