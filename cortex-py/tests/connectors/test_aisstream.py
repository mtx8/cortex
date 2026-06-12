"""AISStream parser + per-MMSI snapshot cache tests (no network)."""

from cortex.connectors.geo.aisstream import AISStreamClient, parse_aisstream_message

_POS = {
    "MessageType": "PositionReport",
    "MetaData": {"MMSI": 265547250, "ShipName": "WERNER", "latitude": 57.6, "longitude": 11.8},
    "Message": {"PositionReport": {"Latitude": 57.6, "Longitude": 11.8, "Sog": 12.8,
                                    "Cog": 290.9, "TrueHeading": 291}},
}
_STATIC = {
    "MessageType": "ShipStaticData",
    "MetaData": {"MMSI": 265547250, "ShipName": "WERNER"},
    "Message": {"ShipStaticData": {"Type": 80, "MaximumStaticDraught": 6.8}},
}


def test_parse_position_report():
    p = parse_aisstream_message(_POS)
    assert p["mmsi"] == 265547250
    assert abs(p["lat"] - 57.6) < 1e-9 and abs(p["lon"] - 11.8) < 1e-9
    assert abs(p["speed_knots"] - 12.8) < 1e-9
    assert p["heading"] == 291 and p["name"] == "WERNER"


def test_parse_static_data():
    p = parse_aisstream_message(_STATIC)
    assert p["mmsi"] == 265547250 and p["ship_type"] == 80
    assert abs(p["draught"] - 6.8) < 1e-9


def test_parse_rejects_missing_mmsi():
    assert parse_aisstream_message({"MetaData": {}}) is None
    assert parse_aisstream_message({}) is None


def test_true_heading_not_available_falls_back_to_cog():
    msg = {"MessageType": "PositionReport",
           "MetaData": {"MMSI": 1, "latitude": 0.0, "longitude": 0.0},
           "Message": {"PositionReport": {"Latitude": 0.0, "Longitude": 0.0, "Sog": 1.0,
                                          "Cog": 123.0, "TrueHeading": 511}}}  # 511 = N/A
    assert parse_aisstream_message(msg)["heading"] == 123.0


def test_cache_merges_position_and_static_into_snapshot():
    c = AISStreamClient(api_key="k")
    assert c.available
    c._apply(_POS)      # position
    c._apply(_STATIC)   # static (ship type)
    snap = c.snapshot()
    assert len(snap) == 1
    v = snap[0]
    assert v["mmsi"] == 265547250
    assert v["is_tanker"] is True and v["category"] == "tanker"
    assert v["ship_type"] == 80
    assert abs(v["lat"] - 57.6) < 1e-9


def test_snapshot_excludes_positionless_vessels():
    c = AISStreamClient(api_key="k")
    c._apply(_STATIC)   # static only, no position yet
    assert c.snapshot() == []


def test_unavailable_without_key():
    assert AISStreamClient(api_key="").available is False


def test_snapshot_drops_and_evicts_stale_entries():
    import time as _t
    from cortex.connectors.geo import aisstream as ais
    c = AISStreamClient(api_key="k")
    c._apply(_POS)
    mmsi = 265547250
    c._cache[mmsi]["_ts"] = _t.monotonic() - (ais._STALE_TTL_S + 10)  # age it out
    assert c.snapshot() == []
    assert mmsi not in c._cache  # stale entry evicted, cache can't grow forever


def test_capacity_evicts_oldest_not_newcomer():
    c = AISStreamClient(api_key="k", max_vessels=2)
    for i, mmsi in enumerate([1, 2, 3]):
        c._apply({"MessageType": "PositionReport",
                  "MetaData": {"MMSI": mmsi, "latitude": float(i), "longitude": float(i)},
                  "Message": {"PositionReport": {"Latitude": float(i), "Longitude": float(i),
                                                 "Sog": 1.0, "TrueHeading": 0}}})
    assert len(c._cache) == 2
    mmsis = {v["mmsi"] for v in c.snapshot()}
    assert 3 in mmsis and 1 not in mmsis  # newcomer kept, oldest evicted


def test_stale_position_frame_does_not_regress_fresh():
    c = AISStreamClient(api_key="k")
    fresh = {"MessageType": "PositionReport",
             "MetaData": {"MMSI": 7, "latitude": 10.0, "longitude": 10.0,
                          "time_utc": "2026-06-12 12:00:00.0 +0000 UTC"},
             "Message": {"PositionReport": {"Latitude": 10.0, "Longitude": 10.0, "Sog": 5.0, "TrueHeading": 0}}}
    stale = {"MessageType": "PositionReport",
             "MetaData": {"MMSI": 7, "latitude": 99.0, "longitude": 99.0,
                          "time_utc": "2026-06-12 11:00:00.0 +0000 UTC"},
             "Message": {"PositionReport": {"Latitude": 99.0, "Longitude": 99.0, "Sog": 1.0, "TrueHeading": 0}}}
    c._apply(fresh)
    c._apply(stale)  # older frame_ms must not overwrite the fresher position
    v = c.snapshot()[0]
    assert abs(v["lat"] - 10.0) < 1e-9
