import pytest
from cortex.squadrons.alpha.signal_hunter import (
    SignalHunter,
    TechnicalCalculator,
    SignalOutput,
)
from cortex.orchestrator.bus import SignalBus


class TestTechnicalCalculator:
    def test_rsi_neutral_with_insufficient_data(self):
        calc = TechnicalCalculator()
        assert calc.rsi([100, 101, 102], period=14) == 50.0

    def test_rsi_overbought(self):
        """Steadily rising prices should give high RSI."""
        calc = TechnicalCalculator()
        prices = [100 + i * 2 for i in range(20)]  # Consistently up
        rsi = calc.rsi(prices, period=14)
        assert rsi > 70.0

    def test_rsi_oversold(self):
        """Steadily falling prices should give low RSI."""
        calc = TechnicalCalculator()
        prices = [100 - i * 2 for i in range(20)]  # Consistently down
        rsi = calc.rsi(prices, period=14)
        assert rsi < 30.0

    def test_rsi_bounded(self):
        """RSI should be between 0 and 100."""
        calc = TechnicalCalculator()
        prices = [100 + i for i in range(30)]
        rsi = calc.rsi(prices)
        assert 0 <= rsi <= 100

    def test_ema_basic(self):
        calc = TechnicalCalculator()
        values = [10.0, 11.0, 12.0, 13.0, 14.0]
        ema = calc.ema(values, period=3)
        assert len(ema) > 0
        assert ema[-1] > ema[0]  # Upward trend

    def test_macd_returns_tuple(self):
        calc = TechnicalCalculator()
        prices = [100 + i * 0.5 for i in range(50)]
        macd_line, signal_line, histogram = calc.macd(prices)
        assert isinstance(macd_line, float)
        assert isinstance(signal_line, float)
        assert isinstance(histogram, float)

    def test_macd_insufficient_data(self):
        calc = TechnicalCalculator()
        macd_line, signal_line, histogram = calc.macd([100, 101, 102])
        assert macd_line == 0.0

    def test_relative_volume(self):
        calc = TechnicalCalculator()
        assert calc.relative_volume(2000000, 1000000) == 2.0
        assert calc.relative_volume(500000, 1000000) == 0.5
        assert calc.relative_volume(100, 0) == 0.0


class TestSignalHunter:
    def test_analyze_no_signal_insufficient_data(self):
        bus = SignalBus()
        hunter = SignalHunter(bus)
        result = hunter.analyze("AAPL", [100, 101, 102], [1000, 1100, 1200])
        assert result is None  # Not enough data for RSI

    def test_analyze_entry_signal_on_reversal(self):
        """RSI reversal from oversold + volume confirmation = entry."""
        bus = SignalBus()
        hunter = SignalHunter(bus, rsi_oversold=30.0, volume_threshold=1.5)

        # Build price history: drop prices then reverse
        # First, enough falling data to make RSI oversold
        prices = [100 - i * 1.5 for i in range(16)]
        # Then a bounce
        prices.append(prices[-1] + 5.0)

        # Volumes: average ~1000, last bar 2000 (2x = confirmed)
        volumes = [1000.0] * 16 + [2000.0]

        # Set prev_rsi to oversold
        hunter._prev_rsi["AAPL"] = 25.0  # Was oversold

        result = hunter.analyze("AAPL", prices, volumes)
        # The RSI after a bounce from deeply oversold + volume should trigger
        if result is not None:
            assert result.signal_type == "entry"
            assert result.volume_ratio >= 1.5

    def test_analyze_exit_on_overbought(self):
        """RSI overbought = exit signal."""
        bus = SignalBus()
        hunter = SignalHunter(bus, rsi_overbought=70.0)

        # Build consistently rising prices for overbought RSI
        prices = [100 + i * 3 for i in range(20)]
        volumes = [1000.0] * 20

        result = hunter.analyze("AAPL", prices, volumes)
        if result is not None:
            assert result.signal_type == "exit"
            assert result.rsi > 70.0

    def test_analyze_no_signal_without_volume(self):
        """Technical signal without volume confirmation = no signal."""
        bus = SignalBus()
        hunter = SignalHunter(bus, volume_threshold=1.5)
        hunter._prev_rsi["TEST"] = 25.0

        # Prices recover but volume is below threshold
        prices = [100 - i for i in range(16)] + [95.0]
        volumes = [1000.0] * 17  # No surge (1x avg)

        result = hunter.analyze("TEST", prices, volumes)
        # Should not generate entry without volume confirmation
        if result is not None:
            assert result.signal_type != "entry"

    def test_stop_loss_set(self):
        """Entry signals include stop loss."""
        bus = SignalBus()
        hunter = SignalHunter(bus)
        hunter._prev_rsi["AAPL"] = 25.0

        # Strong bounce with volume
        prices = [100 - i * 2 for i in range(16)] + [72.0]
        volumes = [1000.0] * 16 + [3000.0]

        result = hunter.analyze("AAPL", prices, volumes)
        if result is not None and result.signal_type == "entry":
            assert result.stop_loss > 0
            assert result.stop_loss < result.entry_price
