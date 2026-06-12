"""GeoRiskContext — a SAFE, one-directional geo-caution layer for ECHO.

The INDIA squadron emits *leading-indicator* geospatial signals
(floating-storage, chokepoint congestion, seismic proximity) onto the SignalBus.
Those are context only — never an order trigger. This class turns the most recent
geo signals into a per-symbol "caution level" in [0, 1] that the RiskGuardian can
consult while sizing a trade.

Hard safety contract (mirrors CLAUDE.md rules #6 + the INDIA charter):
  - Geo caution can ONLY tighten risk: it shrinks position size (multiply by a
    factor in (0, 1]) and, at extreme caution, raises a veto flag.
  - It can NEVER increase size, approve an otherwise-rejected order, trigger an
    order on its own, or weaken the kill switch.
  - Default-safe: a symbol with no live geo signal returns caution 0.0, so the
    sizing path is byte-for-byte unchanged (existing tests stay green).

This class imports NOTHING from the INDIA squadron — it is fed only the dict
payloads that arrive on the bus (Echo/India isolation, CLAUDE.md rule #2).
"""

import time
from dataclasses import dataclass, field

import structlog

log = structlog.get_logger()


@dataclass
class _GeoEntry:
    """A single symbol's live geo caution, with the reasons and an expiry."""

    severity: float
    reasons: list[str] = field(default_factory=list)
    expires_at: float = 0.0


class GeoRiskContext:
    """Per-symbol, TTL-bounded map of current geo caution.

    Fed by ``ingest_signal(signal_type, payload)`` (the RiskGuardian forwards bus
    payloads here). Queried by ``caution_for(symbol)`` / ``reasons_for(symbol)``.
    Caution only ever *reduces* downstream size — see ``size_multiplier``.
    """

    # Geo signal types this context understands. Kept as plain strings so this
    # module never has to import the INDIA squadron.
    GEO_SIGNAL_TYPES = (
        "india.geo_physical_alpha",
        "india.geo_chokepoint_congestion",
        "india.geo_seismic_proximity",
        "india.geo_floating_storage",
    )

    def __init__(
        self,
        ttl_seconds: float = 1800.0,   # geo signals are intermittent; 30 min default
        max_symbols: int = 512,        # hard memory bound on the per-symbol map
        veto_threshold: float = 0.9,   # caution >= this flags a veto
        max_shrink: float = 0.75,      # caution=1.0 can remove at most 75% of size
    ):
        self._ttl = ttl_seconds
        self._max_symbols = max_symbols
        self._veto_threshold = veto_threshold
        # Clamp the shrink coefficient so the multiplier can NEVER reach 0 or go
        # negative — geo can tighten, never zero-out or flip sizing.
        self._k = min(max(max_shrink, 0.0), 0.95)
        self._by_symbol: dict[str, _GeoEntry] = {}
        self._ingested = 0

    # ── ingestion ─────────────────────────────────────────────────────────

    def ingest_signal(self, signal_type: str, payload: dict) -> None:
        """Fold a geo signal payload into the per-symbol caution map.

        Accepts the INDIA payload shape: a ``tickers: [{symbol, direction,
        rationale}]`` list plus a strength expressed as ``severity`` (0-1),
        ``confidence`` (0-1), or ``score`` (0-100). Unknown / malformed payloads
        are ignored — this must never raise into the risk path.
        """
        if signal_type not in self.GEO_SIGNAL_TYPES:
            return
        tickers = payload.get("tickers")
        if not isinstance(tickers, list) or not tickers:
            return

        severity = self._extract_severity(payload)
        if severity <= 0.0:
            return

        now = time.time()
        label = str(payload.get("signal") or signal_type)
        for tk in tickers:
            if not isinstance(tk, dict):
                continue
            symbol = tk.get("symbol")
            if not symbol or not isinstance(symbol, str):
                continue
            rationale = tk.get("rationale") or label
            reason = f"{label}: {rationale} (sev {severity:.2f})"
            self._apply(symbol, severity, reason, now)

        self._ingested += 1
        self._evict_expired(now)
        self._enforce_bound()

    def _apply(self, symbol: str, severity: float, reason: str, now: float) -> None:
        """Merge a new caution reading for a symbol. Caution is the MAX of live
        readings (the most cautious wins); reasons accumulate (bounded)."""
        expires_at = now + self._ttl
        existing = self._by_symbol.get(symbol)
        if existing is not None and existing.expires_at > now:
            existing.severity = max(existing.severity, severity)
            if reason not in existing.reasons:
                existing.reasons.append(reason)
                # Bound the reasons list so a noisy symbol can't grow without limit.
                if len(existing.reasons) > 8:
                    existing.reasons = existing.reasons[-8:]
            existing.expires_at = max(existing.expires_at, expires_at)
        else:
            self._by_symbol[symbol] = _GeoEntry(
                severity=severity, reasons=[reason], expires_at=expires_at
            )

    @staticmethod
    def _extract_severity(payload: dict) -> float:
        """Normalize the various strength fields into a [0, 1] severity."""
        for key in ("severity", "confidence"):
            val = payload.get(key)
            if isinstance(val, (int, float)):
                return _clamp01(float(val))
        score = payload.get("score")
        if isinstance(score, (int, float)):
            # Maritime scores are 0-100.
            return _clamp01(float(score) / 100.0)
        return 0.0

    # ── housekeeping ──────────────────────────────────────────────────────

    def _evict_expired(self, now: float | None = None) -> None:
        now = time.time() if now is None else now
        stale = [s for s, e in self._by_symbol.items() if e.expires_at <= now]
        for s in stale:
            del self._by_symbol[s]

    def _enforce_bound(self) -> None:
        """Hard cap the map size; drop the soonest-to-expire entries first."""
        if len(self._by_symbol) <= self._max_symbols:
            return
        ordered = sorted(self._by_symbol.items(), key=lambda kv: kv[1].expires_at)
        for symbol, _ in ordered[: len(self._by_symbol) - self._max_symbols]:
            del self._by_symbol[symbol]

    # ── pure queries (used by the risk path) ──────────────────────────────

    def caution_for(self, symbol: str) -> float:
        """Current geo caution for ``symbol`` in [0, 1]. 0.0 if none/expired."""
        if not symbol:
            return 0.0
        entry = self._by_symbol.get(symbol)
        if entry is None:
            return 0.0
        if entry.expires_at <= time.time():
            # Lazily drop the stale entry so queries stay self-cleaning.
            del self._by_symbol[symbol]
            return 0.0
        return _clamp01(entry.severity)

    def reasons_for(self, symbol: str) -> list[str]:
        """Live caution reasons for ``symbol`` (empty if none/expired)."""
        if not symbol or self.caution_for(symbol) <= 0.0:
            return []
        return list(self._by_symbol[symbol].reasons)

    def size_multiplier(self, symbol: str) -> float:
        """Sizing factor in (0, 1] for ``symbol``. ALWAYS <= 1.0 — geo can only
        shrink. With no geo signal this is exactly 1.0 (no-op)."""
        caution = self.caution_for(symbol)
        if caution <= 0.0:
            return 1.0
        factor = 1.0 - self._k * caution
        # Clamp into (0, 1]: never grows, never zeroes out the position.
        return min(1.0, max(0.05, factor))

    def should_veto(self, symbol: str) -> bool:
        """True only at extreme caution. A veto FLAGS the order (adds caution);
        it never approves anything. The kill switch / base checks still win."""
        return self.caution_for(symbol) >= self._veto_threshold

    # ── introspection ─────────────────────────────────────────────────────

    @property
    def tracked_symbols(self) -> int:
        self._evict_expired()
        return len(self._by_symbol)

    @property
    def ingested_count(self) -> int:
        return self._ingested

    def to_dict(self) -> dict:
        self._evict_expired()
        return {
            "tracked_symbols": len(self._by_symbol),
            "ingested": self._ingested,
            "ttl_seconds": self._ttl,
            "veto_threshold": self._veto_threshold,
            "max_shrink": self._k,
        }


def _clamp01(x: float) -> float:
    # NaN is the one float that compares False against every bound, so the naive
    # `x < 0 / x > 1` guards would let it slip through and poison the caution map
    # (caution=NaN surfaces on RiskDecision/the bus, suppresses the review flag on
    # an order whose size WAS silently shrunk, and is one refactor away from
    # `int(qty * NaN)` raising inside the synchronous risk hot path). Treat any
    # non-finite-low / NaN value as the SAFE no-caution floor of 0.0.
    if not x == x:  # NaN
        return 0.0
    if x < 0.0:
        return 0.0
    if x > 1.0:
        return 1.0
    return x
