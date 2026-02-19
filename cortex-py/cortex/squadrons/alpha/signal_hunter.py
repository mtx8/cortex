"""Signal Hunter — RSI + MACD + Volume threshold scanner.
Generates entry/exit signals for equity trades.

Technical indicators:
- RSI(14): Oversold <30, Overbought >70
- MACD(12,26,9): Signal line crossover
- Volume: Above 1.5x 20-day average confirms momentum

Entry conditions (all must be true):
- RSI crosses above 30 (reversal from oversold) OR MACD bullish crossover
- Volume confirmation (>1.5x average)

Exit conditions:
- RSI crosses above 70 (overbought)
- MACD bearish crossover
"""

from dataclasses import dataclass, field
from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


@dataclass
class OHLCV:
    open: float
    high: float
    low: float
    close: float
    volume: float


@dataclass
class SignalOutput:
    symbol: str
    signal_type: str  # "entry" | "exit"
    direction: str  # "long" | "short"
    confidence: float  # 0.0 - 1.0
    rsi: float
    macd_line: float
    macd_signal: float
    volume_ratio: float
    entry_price: float
    stop_loss: float
    reasons: list[str] = field(default_factory=list)


class TechnicalCalculator:
    """Pure calculation functions for technical indicators. No side effects."""

    @staticmethod
    def rsi(closes: list[float], period: int = 14) -> float:
        """Calculate RSI using Wilder's smoothing method."""
        if len(closes) < period + 1:
            return 50.0  # Neutral when insufficient data

        deltas = [closes[i] - closes[i - 1] for i in range(1, len(closes))]
        recent = deltas[-(period):]

        gains = [d if d > 0 else 0.0 for d in recent]
        losses = [-d if d < 0 else 0.0 for d in recent]

        avg_gain = sum(gains) / period
        avg_loss = sum(losses) / period

        if avg_loss == 0:
            return 100.0
        rs = avg_gain / avg_loss
        return 100.0 - (100.0 / (1.0 + rs))

    @staticmethod
    def ema(values: list[float], period: int) -> list[float]:
        """Exponential moving average."""
        if not values:
            return []
        if len(values) < period:
            return [sum(values) / len(values)]

        multiplier = 2.0 / (period + 1)
        ema_values = [sum(values[:period]) / period]

        for price in values[period:]:
            ema_values.append((price - ema_values[-1]) * multiplier + ema_values[-1])

        return ema_values

    @staticmethod
    def macd(
        closes: list[float],
        fast: int = 12,
        slow: int = 26,
        signal_period: int = 9,
    ) -> tuple[float, float, float]:
        """Returns (macd_line, signal_line, histogram)."""
        if len(closes) < slow + signal_period:
            return 0.0, 0.0, 0.0

        fast_ema = TechnicalCalculator.ema(closes, fast)
        slow_ema = TechnicalCalculator.ema(closes, slow)

        # Align lengths — fast EMA is longer than slow EMA
        min_len = min(len(fast_ema), len(slow_ema))
        macd_line_values = [
            fast_ema[len(fast_ema) - min_len + i] - slow_ema[len(slow_ema) - min_len + i]
            for i in range(min_len)
        ]

        if len(macd_line_values) < signal_period:
            return macd_line_values[-1] if macd_line_values else 0.0, 0.0, 0.0

        signal_ema = TechnicalCalculator.ema(macd_line_values, signal_period)

        macd_val = macd_line_values[-1]
        signal_val = signal_ema[-1] if signal_ema else 0.0
        histogram = macd_val - signal_val

        return macd_val, signal_val, histogram

    @staticmethod
    def relative_volume(current_volume: float, avg_volume: float) -> float:
        """Relative volume ratio vs average."""
        if avg_volume <= 0:
            return 0.0
        return current_volume / avg_volume


class SignalHunter(BaseAgent):
    agent_id = "signal_hunter"
    squadron = "alpha"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        rsi_period: int = 14,
        rsi_oversold: float = 30.0,
        rsi_overbought: float = 70.0,
        volume_threshold: float = 1.5,
        lookback: int = 50,
    ):
        super().__init__(bus)
        self._rsi_period = rsi_period
        self._rsi_oversold = rsi_oversold
        self._rsi_overbought = rsi_overbought
        self._volume_threshold = volume_threshold
        self._lookback = lookback

        # Price history per symbol
        self._closes: dict[str, deque[float]] = {}
        self._volumes: dict[str, deque[float]] = {}
        self._prev_rsi: dict[str, float] = {}
        self._prev_macd: dict[str, float] = {}

        self._calc = TechnicalCalculator()

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload
        symbol = payload.get("symbol")
        if not symbol:
            return

        close = payload.get("close", 0.0)
        volume = payload.get("volume", 0.0)

        if close <= 0:
            return

        # Update history
        if symbol not in self._closes:
            self._closes[symbol] = deque(maxlen=self._lookback)
            self._volumes[symbol] = deque(maxlen=self._lookback)

        self._closes[symbol].append(close)
        self._volumes[symbol].append(volume)

        # Need enough data
        closes = list(self._closes[symbol])
        if len(closes) < self._rsi_period + 1:
            return

        result = self.analyze(symbol, closes, list(self._volumes[symbol]))
        if result:
            if result.signal_type == "entry":
                await self.emit(
                    SignalTypes.ENTRY_SIGNAL,
                    payload={
                        "symbol": result.symbol,
                        "direction": result.direction,
                        "confidence": result.confidence,
                        "entry_price": result.entry_price,
                        "stop_loss": result.stop_loss,
                        "asset_class": "equity",
                        "side": "buy" if result.direction == "long" else "sell",
                        "rsi": result.rsi,
                        "macd": result.macd_line,
                        "volume_ratio": result.volume_ratio,
                        "reasons": result.reasons,
                    },
                    priority=SignalPriority.NORMAL,
                )
            elif result.signal_type == "exit":
                await self.emit(
                    SignalTypes.EXIT_SIGNAL,
                    payload={
                        "symbol": result.symbol,
                        "direction": result.direction,
                        "rsi": result.rsi,
                        "reasons": result.reasons,
                    },
                    priority=SignalPriority.HIGH,
                )

    def analyze(
        self, symbol: str, closes: list[float], volumes: list[float]
    ) -> SignalOutput | None:
        """Pure analysis function — returns signal or None."""
        rsi = self._calc.rsi(closes, self._rsi_period)
        macd_line, signal_line, histogram = self._calc.macd(closes)

        avg_volume = sum(volumes[:-1]) / max(1, len(volumes) - 1) if len(volumes) > 1 else 0
        vol_ratio = self._calc.relative_volume(volumes[-1], avg_volume) if volumes else 0.0

        prev_rsi = self._prev_rsi.get(symbol, 50.0)
        prev_macd = self._prev_macd.get(symbol, 0.0)

        self._prev_rsi[symbol] = rsi
        self._prev_macd[symbol] = macd_line

        current_price = closes[-1]
        reasons: list[str] = []

        # Entry conditions
        rsi_reversal = prev_rsi <= self._rsi_oversold and rsi > self._rsi_oversold
        macd_crossover = prev_macd <= signal_line and macd_line > signal_line
        volume_confirmed = vol_ratio >= self._volume_threshold

        if rsi_reversal:
            reasons.append(f"RSI reversal from oversold ({prev_rsi:.1f} -> {rsi:.1f})")
        if macd_crossover:
            reasons.append(f"MACD bullish crossover ({macd_line:.4f} > {signal_line:.4f})")
        if volume_confirmed:
            reasons.append(f"Volume confirmed ({vol_ratio:.1f}x avg)")

        # Need at least one technical signal + volume confirmation
        has_technical = rsi_reversal or macd_crossover
        if has_technical and volume_confirmed:
            # Confidence based on how many signals align
            confidence = 0.5
            if rsi_reversal:
                confidence += 0.2
            if macd_crossover:
                confidence += 0.2
            if vol_ratio >= 2.0:
                confidence += 0.1

            # Stop loss: 2% below entry
            stop_loss = current_price * 0.98

            return SignalOutput(
                symbol=symbol,
                signal_type="entry",
                direction="long",
                confidence=min(confidence, 1.0),
                rsi=rsi,
                macd_line=macd_line,
                macd_signal=signal_line,
                volume_ratio=vol_ratio,
                entry_price=current_price,
                stop_loss=stop_loss,
                reasons=reasons,
            )

        # Exit conditions
        exit_reasons: list[str] = []
        if rsi >= self._rsi_overbought:
            exit_reasons.append(f"RSI overbought ({rsi:.1f})")
        if prev_macd > signal_line and macd_line <= signal_line:
            exit_reasons.append("MACD bearish crossover")

        if exit_reasons:
            return SignalOutput(
                symbol=symbol,
                signal_type="exit",
                direction="long",
                confidence=0.7,
                rsi=rsi,
                macd_line=macd_line,
                macd_signal=signal_line,
                volume_ratio=vol_ratio,
                entry_price=current_price,
                stop_loss=0.0,
                reasons=exit_reasons,
            )

        return None

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._closes),
            "rsi_period": self._rsi_period,
        })
        return base
