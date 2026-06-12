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
