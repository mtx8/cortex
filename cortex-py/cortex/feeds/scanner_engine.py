"""ScannerEngine — Rust-accelerated technical scanner.

Thin async-friendly wrapper over the cortex_scanner Rust core
(scan_symbols_with_history: vectorized RSI/MACD/momentum/volume composite scoring
with rayon parallelism). This is the "powerful scanner" spine — real indicator math
in Rust, not random demo scores. Degrades to an empty result if the compiled core
is absent so the app never hard-fails.
"""

from __future__ import annotations

import structlog

log = structlog.get_logger()

try:
    import cortex_scanner as _cs  # type: ignore
except ImportError:  # pragma: no cover
    _cs = None

# RSI/MACD need enough history; fewer bars than this can't be scored meaningfully.
_MIN_BARS = 30


class ScannerEngine:
    """Composite-scored technical scan over per-symbol price history."""

    @property
    def available(self) -> bool:
        return _cs is not None

    def scan(
        self,
        price_history: dict[str, list[float]],
        volumes: dict[str, float] | None = None,
        avg_volumes: dict[str, float] | None = None,
        min_score: float = 0.0,
    ) -> list[dict]:
        """Return composite-scored results (sorted desc). Each dict has symbol,
        composite_score, momentum_score, volume_score, rsi, macd_histogram,
        trend_score. Symbols with < _MIN_BARS history are skipped."""
        if _cs is None:
            return []
        volumes = volumes or {}
        avg_volumes = avg_volumes or {}
        symbols = [s for s, h in price_history.items() if h and len(h) >= _MIN_BARS]
        if not symbols:
            return []
        ph = [price_history[s] for s in symbols]
        vol = [float(volumes.get(s, 0.0)) for s in symbols]
        avg = [float(avg_volumes.get(s, 0.0)) for s in symbols]
        try:
            results = _cs.scan_symbols_with_history(symbols, ph, vol, avg)
        except Exception as e:  # numeric edge cases never crash the loop
            log.warning("scanner_engine.error", error=str(e))
            return []
        out = [r.to_dict() for r in results]
        out = [r for r in out if r.get("composite_score", 0.0) >= min_score]
        out.sort(key=lambda r: r.get("composite_score", 0.0), reverse=True)
        return out

    def to_dict(self) -> dict:
        return {"available": self.available, "min_bars": _MIN_BARS}
