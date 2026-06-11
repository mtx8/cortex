"""End-to-end smoke test of the cortex_scanner geo-intelligence PyO3 surface.

Offline-safe: the only network-shaped calls (geo_fetch) assert the SSRF/https
guards reject before any byte leaves. Run after `maturin develop` / wheel install.
"""
import cortex_scanner as cs


def main() -> None:
    print("version:", cs.__version__)
    print("MAX_FETCH_BYTES:", cs.MAX_FETCH_BYTES)

    # --- egress allowlist (no network) ---
    assert cs.validate_host("earthquake.usgs.gov") is True
    assert cs.validate_host("api.eia.gov") is True
    assert cs.validate_host("earthquake.usgs.gov.evil.com") is False  # SSRF spoof
    assert cs.validate_host("evil.com") is False
    hosts = cs.allowed_hosts()
    assert "stream.aisstream.io" in hosts and "api.stlouisfed.org" in hosts
    print(f"allowlist: {len(hosts)} hosts, spoof rejected OK")

    # geo_fetch must refuse a disallowed host before any byte leaves
    try:
        cs.geo_fetch("https://attacker.example/secret")
        raise SystemExit("FAIL: geo_fetch did not reject disallowed host")
    except ValueError as e:
        print("geo_fetch SSRF guard:", e)
    try:
        cs.geo_fetch("http://earthquake.usgs.gov/x")
        raise SystemExit("FAIL: geo_fetch allowed http scheme")
    except ValueError as e:
        print("geo_fetch https-only guard:", e)

    # --- geo math + chokepoints ---
    d = cs.haversine_km(51.5074, -0.1278, 48.8566, 2.3522)  # London -> Paris
    assert 335 < d < 350, d
    print(f"haversine London->Paris: {d:.1f} km")
    assert cs.chokepoint_at(26.6, 56.3) == "Strait of Hormuz"
    assert cs.chokepoint_at(0.0, -140.0) is None
    cps = cs.chokepoints()
    print(f"chokepoints: {len(cps)} (top: {cps[0]['name']} {cps[0]['throughput_mbd']} mb/d)")

    # --- maritime physical-alpha ---
    assert cs.is_tanker(80) and not cs.is_tanker(70)
    assert cs.ship_type_category(80) == "tanker"
    fs = cs.floating_storage_index(
        speeds_knots=[0.1, 0.2, 5.0, 0.0],
        hours_idle=[200.0, 300.0, 400.0, 10.0],
        laden=[True, True, True, True],
    )
    assert fs["count"] == 2, fs
    print("floating_storage_index:", fs)

    cong = cs.chokepoint_congestion(
        lats=[26.6, 26.55, 26.62, 0.0],
        lons=[56.3, 56.2, 56.25, -140.0],
        speeds_knots=[1.0, 0.5, 2.0, 12.0],
        ship_types=[80, 84, 70, 80],
    )
    hz = [c for c in cong if c["name"] == "Strait of Hormuz"][0]
    assert hz["vessel_count"] == 3 and hz["tanker_count"] == 2, hz
    print("chokepoint_congestion Hormuz:",
          {k: (round(v, 2) if isinstance(v, float) else v) for k, v in hz.items()})

    # --- parsers ---
    ev = cs.parse_usgs_geojson(
        '{"features":[{"id":"x","properties":{"mag":5.5,"place":"Test",'
        '"time":1700000000000},"geometry":{"coordinates":[-120.0,37.0,9.0]}}]}')
    assert len(ev) == 1 and abs(ev[0].magnitude - 5.5) < 1e-9
    print("parse_usgs:", ev[0].__repr__(), "| dict keys:", list(ev[0].to_dict().keys()))

    vs = cs.parse_digitraffic_ais(
        '{"features":[{"mmsi":230999,"geometry":{"coordinates":[24.9,60.1]},'
        '"properties":{"sog":11.2,"heading":200,"shipType":80}}]}')
    assert len(vs) == 1 and vs[0].is_tanker and vs[0].category == "tanker"
    print("parse_ais:", vs[0].__repr__(), "| tanker:", vs[0].is_tanker)

    print("\nALL SMOKE TESTS PASSED")


if __name__ == "__main__":
    main()
