"""GeoEgressClient — the Python face of the Rust geo-intelligence core.

Every outbound geo/OSINT request goes through the hardened `cortex_scanner`
egress chokepoint (https-only, exact-host allowlist, redirect containment, byte
cap, secret-free errors) — never raw httpx. URLs are built server-side here so no
caller ever constructs an external URL. The blocking Rust calls run in the default
thread-pool executor so the asyncio event loop is never blocked (CLAUDE.md: async
+ uvloop). If the compiled extension is not installed, `available` is False and the
geo feed/agents degrade gracefully instead of crashing the app.
"""

from __future__ import annotations

import asyncio
import structlog

log = structlog.get_logger()

try:  # the maturin-built extension (cortex-rs). Optional at runtime.
    import cortex_scanner as _cs  # type: ignore
except ImportError:  # pragma: no cover - exercised in environments without the wheel
    _cs = None
    log.warning("geo.rust_core_missing",
                hint="build cortex-rs: `cd cortex-rs && maturin develop` to enable geo-intelligence")


# ── Canonical feed URLs (built server-side; callers never pass raw URLs) ──────

USGS_WINDOWS = {
    "all_hour": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_hour.geojson",
    "all_day": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson",
    "2.5_day": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson",
}

# Digitraffic Baltic AIS — free, keyless, no bbox required. Our live tanker spine
# until an AISStream key is provided for global coverage.
DIGITRAFFIC_AIS_LOCATIONS = "https://meri.digitraffic.fi/api/ais/v1/locations"
# Static vessel metadata (shipType / draught / name) keyed by MMSI — the locations
# endpoint omits these, so we enrich with this for real tanker classification.
DIGITRAFFIC_AIS_VESSELS = "https://meri.digitraffic.fi/api/ais/v1/vessels"


class GeoEgressClient:
    """Async wrappers around the synchronous Rust egress + parsers."""

    def __init__(self, default_timeout_ms: int = 12000):
        self._timeout_ms = default_timeout_ms

    @property
    def available(self) -> bool:
        """True if the compiled cortex_scanner geo core is importable."""
        return _cs is not None

    @property
    def allowed_hosts(self) -> list[str]:
        return list(_cs.allowed_hosts()) if _cs is not None else []

    # A full regional AIS snapshot can exceed the 5 MiB default; this trusted,
    # allowlisted feed opts into a higher cap (still under the Rust hard ceiling).
    _AIS_MAX_BYTES = 24 * 1024 * 1024

    async def _fetch(self, url: str, headers: dict | None = None,
                     timeout_ms: int | None = None, max_bytes: int | None = None):
        """Run the hardened blocking GET on the thread pool. Returns FetchResult."""
        if _cs is None:
            raise RuntimeError("cortex_scanner geo core not installed")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, _cs.geo_fetch, url, headers,
            timeout_ms or self._timeout_ms, max_bytes or (5 * 1024 * 1024),
        )

    # ── Typed feeds ──────────────────────────────────────────────────────────

    async def fetch_earthquakes(self, window: str = "all_hour") -> list:
        """Fetch + parse USGS earthquakes. Returns list[GeoEvent] (possibly empty)."""
        if _cs is None:
            return []
        url = USGS_WINDOWS.get(window, USGS_WINDOWS["all_hour"])
        res = await self._fetch(url)
        if not res.ok:
            log.warning("geo.usgs_http", status=res.status)
            return []
        try:
            return _cs.parse_usgs_geojson(res.body)
        except ValueError as e:  # truncated/malformed body — degrade, don't crash
            log.warning("geo.usgs_parse", error=str(e), truncated=res.truncated)
            return []

    async def fetch_ais_vessels(self) -> list:
        """Fetch + parse live Baltic AIS positions. Returns list[Vessel]."""
        if _cs is None:
            return []
        res = await self._fetch(DIGITRAFFIC_AIS_LOCATIONS, max_bytes=self._AIS_MAX_BYTES)
        if not res.ok:
            log.warning("geo.ais_http", status=res.status)
            return []
        if res.truncated:
            # Body hit even the raised cap — a partial JSON snapshot is unparseable
            # as a whole; skip this poll rather than crash. (AISStream WS spine in P5
            # removes this single-blob limitation entirely.)
            log.warning("geo.ais_truncated", bytes=len(res.body))
            return []
        try:
            return _cs.parse_digitraffic_ais(res.body)
        except ValueError as e:
            log.warning("geo.ais_parse", error=str(e))
            return []

    async def fetch_ais_metadata(self) -> dict[int, dict]:
        """Fetch static vessel metadata keyed by MMSI: {mmsi: {ship_type, draught_m,
        name}}. The locations endpoint omits ship type, so this is what makes tanker
        classification real. Refreshed infrequently (static data). Returns {} on any
        failure so the feed degrades to position-only."""
        if _cs is None:
            return {}
        res = await self._fetch(DIGITRAFFIC_AIS_VESSELS, max_bytes=self._AIS_MAX_BYTES)
        if not res.ok or res.truncated:
            if res.truncated:
                log.warning("geo.ais_meta_truncated", bytes=len(res.body))
            return {}
        try:
            import orjson
            data = orjson.loads(res.body)
        except Exception as e:
            log.warning("geo.ais_meta_parse", error=str(e))
            return {}
        out: dict[int, dict] = {}
        if isinstance(data, list):
            for v in data:
                if not isinstance(v, dict):
                    continue
                mmsi = v.get("mmsi")
                if mmsi is None:
                    continue
                try:
                    out[int(mmsi)] = {
                        "ship_type": int(v.get("shipType", 0) or 0),
                        "draught_m": float(v.get("draught", 0) or 0) / 10.0,  # decimetres -> m
                        "name": (v.get("name") or "").strip(),
                    }
                except (TypeError, ValueError):
                    continue
        return out

    # ── Diagnostics ──────────────────────────────────────────────────────────

    def to_dict(self) -> dict:
        return {
            "available": self.available,
            "allowed_hosts": len(self.allowed_hosts),
            "version": getattr(_cs, "__version__", None) if _cs is not None else None,
        }
