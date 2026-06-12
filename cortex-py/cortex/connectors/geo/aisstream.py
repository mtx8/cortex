"""AISStream.io WebSocket connector — the GLOBAL live tanker spine.

AISStream streams worldwide AIS as individual JSON frames (PositionReport for
movement, ShipStaticData for ship type/draught/name). This connector maintains a
per-MMSI merged snapshot the geo feed reads each poll, giving global coverage
(Hormuz/Suez/etc.) beyond Digitraffic's Baltic box. Live operation needs a FREE
AISStream API key (config.aisstream_api_key); without one it is inert.

Egress note: this is a WebSocket (wss://stream.aisstream.io), not an HTTP GET, so it
does not pass through the Rust guarded_get chokepoint. The host is on the egress
allowlist, the key lives in config/Keychain (never the WebView), and the only data
sent upstream is the subscription (key + bounding boxes + message-type filter).
"""

from __future__ import annotations

import asyncio
import datetime
import time
import structlog

log = structlog.get_logger()

AISSTREAM_URL = "wss://stream.aisstream.io/v0/stream"
# Default to the oil-flow corridors (focused signal + bounded volume) rather than
# the whole world, which would exceed any cache cap in minutes. Each box is
# [[lat1, lon1], [lat2, lon2]].
_OIL_CORRIDORS = [
    [[24.0, 54.0], [28.0, 58.0]],    # Strait of Hormuz
    [[10.0, 32.0], [32.0, 44.0]],    # Red Sea / Suez / Bab-el-Mandeb
    [[-2.0, 99.0], [7.0, 105.0]],    # Malacca / Singapore
    [[40.0, 26.0], [42.5, 30.0]],    # Turkish Straits / Bosphorus
    [[26.0, -98.0], [31.0, -88.0]],  # US Gulf export terminals
    [[35.0, -7.0], [37.0, -4.0]],    # Strait of Gibraltar
    [[7.0, -81.0], [10.0, -78.0]],   # Panama
]
# Drop vessels not heard from in this long (stale = position-frozen phantom).
_STALE_TTL_S = 1800.0  # 30 min


def parse_aisstream_message(msg: dict) -> dict | None:
    """Parse one AISStream frame into a partial vessel dict, or None if unusable.
    PositionReport carries lat/lon/speed/heading; ShipStaticData carries ship_type/
    draught. The caller merges partials by MMSI."""
    if not isinstance(msg, dict):
        return None
    meta = msg.get("MetaData") or {}
    mmsi = meta.get("MMSI")
    if mmsi is None:
        return None
    out: dict = {"mmsi": int(mmsi)}
    name = meta.get("ShipName")
    if isinstance(name, str) and name.strip():
        out["name"] = name.strip()
    # Best-effort frame time for recency ordering (AISStream MetaData.time_utc looks
    # like "2026-06-12 12:00:00.0 +0000 UTC").
    tu = meta.get("time_utc")
    if isinstance(tu, str) and len(tu) >= 19:
        try:
            dt = datetime.datetime.strptime(tu[:19], "%Y-%m-%d %H:%M:%S").replace(
                tzinfo=datetime.timezone.utc)
            out["frame_ms"] = int(dt.timestamp() * 1000)
        except (ValueError, OverflowError):
            pass

    mtype = msg.get("MessageType")
    body = (msg.get("Message") or {}).get(mtype) or {}
    if mtype == "PositionReport":
        lat = body.get("Latitude", meta.get("latitude"))
        lon = body.get("Longitude", meta.get("longitude"))
        if lat is None or lon is None:
            return None
        out["lat"] = float(lat)
        out["lon"] = float(lon)
        out["speed_knots"] = float(body.get("Sog", 0) or 0)
        heading = body.get("TrueHeading")
        if heading in (None, 511):  # 511 = "not available"
            heading = body.get("Cog", 0)
        out["heading"] = float(heading or 0)
    elif mtype == "ShipStaticData":
        out["ship_type"] = int(body.get("Type", 0) or 0)
        draught = body.get("MaximumStaticDraught", 0) or 0
        out["draught"] = float(draught)
    else:
        # Other message types carry only identity/name — useful for enrichment.
        if "name" not in out:
            return None
    return out


class AISStreamClient:
    """Maintains a live per-MMSI vessel snapshot from the AISStream WebSocket."""

    def __init__(self, api_key: str, bboxes: list | None = None, max_vessels: int = 60000):
        self._key = api_key
        self._bboxes = bboxes or _OIL_CORRIDORS
        self._max = max_vessels
        self._cache: dict[int, dict] = {}
        self._running = False
        self._messages = 0

    @property
    def available(self) -> bool:
        return bool(self._key)

    def _apply(self, msg: dict) -> None:
        """Merge one parsed frame into the cache: position frames update
        lat/lon/speed/heading, static frames update ship_type/draught/name. Tracks a
        last-seen time per entry (for TTL + capacity eviction) and guards position
        overwrites by frame time so an out-of-order stale frame can't regress a fresh
        one. Public-ish for tests."""
        p = parse_aisstream_message(msg)
        if not p:
            return
        self._messages += 1
        mmsi = p["mmsi"]
        now = time.monotonic()
        is_position = "lat" in p
        cur = self._cache.get(mmsi)
        if cur is None:
            if len(self._cache) >= self._max:
                # Evict the oldest entry rather than dropping the newcomer forever.
                oldest = min(self._cache, key=lambda k: self._cache[k].get("_ts", 0.0))
                del self._cache[oldest]
            p["_ts"] = now
            p["_ts_wall"] = time.time()
            if is_position and "frame_ms" in p:
                p["_pos_frame_ms"] = p["frame_ms"]
            self._cache[mmsi] = p
            return

        # Existing entry: guard the position overwrite against stale frames.
        if is_position and "frame_ms" in p and cur.get("_pos_frame_ms") is not None \
                and p["frame_ms"] < cur["_pos_frame_ms"]:
            for k in ("ship_type", "draught", "name"):   # static identity only
                if k in p:
                    cur[k] = p[k]
        else:
            cur.update(p)
            if is_position and "frame_ms" in p:
                cur["_pos_frame_ms"] = p["frame_ms"]
        cur["_ts"] = now
        cur["_ts_wall"] = time.time()

    def snapshot(self) -> list[dict]:
        """Current, non-stale vessels with a known position (geo-feed shape).
        Entries unheard from for > _STALE_TTL_S are dropped (no frozen phantoms)."""
        out = []
        now = time.monotonic()
        stale = []
        for mmsi, v in self._cache.items():
            if now - v.get("_ts", 0.0) > _STALE_TTL_S:
                stale.append(mmsi)
                continue
            if "lat" not in v or "lon" not in v:
                continue
            st = int(v.get("ship_type", 0))
            out.append({
                "mmsi": v["mmsi"], "lat": v["lat"], "lon": v["lon"],
                "speed_knots": v.get("speed_knots", 0.0), "heading": v.get("heading", 0.0),
                "ship_type": st, "is_tanker": 80 <= st <= 89,
                "category": "tanker" if 80 <= st <= 89 else ("cargo" if 70 <= st <= 79 else "other"),
                "name": v.get("name", ""), "draught": v.get("draught", 0.0),
                "chokepoint": None,
                "timestamp_ms": int(v.get("frame_ms") or v.get("_ts_wall", 0.0) * 1000),
            })
        for mmsi in stale:   # actually evict stale entries so the cache can't grow
            self._cache.pop(mmsi, None)
        return out

    async def start(self) -> None:
        if not self.available:
            log.info("aisstream.no_key")
            return
        try:
            import websockets
        except ImportError:
            log.warning("aisstream.websockets_missing")
            return
        import orjson
        sub = {"APIKey": self._key, "BoundingBoxes": self._bboxes,
               "FilterMessageTypes": ["PositionReport", "ShipStaticData"]}
        self._running = True
        log.info("aisstream.starting", bboxes=len(self._bboxes))
        while self._running:
            try:
                async with websockets.connect(AISSTREAM_URL, ping_interval=20) as ws:
                    await ws.send(orjson.dumps(sub).decode())
                    async for raw in ws:
                        if not self._running:
                            break
                        try:
                            self._apply(orjson.loads(raw))
                        except Exception:
                            continue
            except asyncio.CancelledError:
                break
            except Exception as e:
                log.warning("aisstream.reconnect", error=str(e))
                try:
                    await asyncio.sleep(5)
                except asyncio.CancelledError:
                    break
        log.info("aisstream.stopped", messages=self._messages)

    async def stop(self) -> None:
        self._running = False

    def to_dict(self) -> dict:
        return {"available": self.available, "running": self._running,
                "vessels": len(self._cache), "messages": self._messages}
