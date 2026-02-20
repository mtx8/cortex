"""Tests for AlertEngine — price alert monitoring and triggering."""

import pytest
from unittest.mock import AsyncMock

from cortex.feeds.alerts import AlertEngine, AlertType, AlertStatus, Alert


# ─── Fixtures ────────────────────────────────────────────────────────

@pytest.fixture
def engine():
    return AlertEngine()


# ─── Create / Delete Tests ───────────────────────────────────────────

def test_create_alert(engine):
    """Test creating an alert stores it correctly."""
    alert = engine.create_alert("a1", "AAPL", "price_above", 200.0)

    assert alert.id == "a1"
    assert alert.symbol == "AAPL"
    assert alert.alert_type == AlertType.PRICE_ABOVE
    assert alert.threshold == 200.0
    assert alert.status == AlertStatus.ACTIVE
    assert alert.message == ""
    assert alert.triggered_at is None
    assert len(engine.get_alerts()) == 1


def test_create_alert_lowercased_symbol(engine):
    """Test that symbol is uppercased on creation."""
    alert = engine.create_alert("a1", "aapl", "price_below", 150.0)
    assert alert.symbol == "AAPL"


def test_delete_alert(engine):
    """Test deleting an alert removes it from the engine."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    assert len(engine.get_alerts()) == 1

    result = engine.delete_alert("a1")
    assert result is True
    assert len(engine.get_alerts()) == 0


def test_delete_alert_nonexistent(engine):
    """Test deleting a non-existent alert returns False."""
    result = engine.delete_alert("nonexistent")
    assert result is False


# ─── Get Alerts Tests ────────────────────────────────────────────────

def test_get_alerts_filter_by_symbol(engine):
    """Test filtering alerts by symbol."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    engine.create_alert("a2", "MSFT", "price_below", 350.0)
    engine.create_alert("a3", "AAPL", "pct_change", 5.0)

    aapl_alerts = engine.get_alerts(symbol="AAPL")
    assert len(aapl_alerts) == 2
    assert all(a.symbol == "AAPL" for a in aapl_alerts)

    msft_alerts = engine.get_alerts(symbol="MSFT")
    assert len(msft_alerts) == 1

    all_alerts = engine.get_alerts()
    assert len(all_alerts) == 3


def test_get_alerts_filter_case_insensitive(engine):
    """Test filtering alerts by symbol is case-insensitive."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    alerts = engine.get_alerts(symbol="aapl")
    assert len(alerts) == 1


# ─── Price Trigger Tests ─────────────────────────────────────────────

def test_price_above_triggered(engine):
    """Test price_above alert triggers when price crosses above threshold."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)

    # Price below threshold — should not trigger
    triggered = engine.update_price("AAPL", 195.0)
    assert len(triggered) == 0

    # Price at threshold — should trigger
    triggered = engine.update_price("AAPL", 200.0)
    assert len(triggered) == 1
    assert triggered[0].id == "a1"
    assert triggered[0].status == AlertStatus.TRIGGERED
    assert triggered[0].triggered_at is not None
    assert "crossed above" in triggered[0].message


def test_price_below_triggered(engine):
    """Test price_below alert triggers when price drops below threshold."""
    engine.create_alert("a1", "AAPL", "price_below", 150.0)

    # Price above threshold — should not trigger
    triggered = engine.update_price("AAPL", 160.0)
    assert len(triggered) == 0

    # Price at threshold — should trigger
    triggered = engine.update_price("AAPL", 150.0)
    assert len(triggered) == 1
    assert triggered[0].id == "a1"
    assert triggered[0].status == AlertStatus.TRIGGERED
    assert "dropped below" in triggered[0].message


def test_pct_change_triggered(engine):
    """Test pct_change alert triggers when price moves by threshold percent."""
    engine.create_alert("a1", "AAPL", "pct_change", 5.0)

    # First price sets the base
    triggered = engine.update_price("AAPL", 100.0)
    assert len(triggered) == 0

    # 3% move — should not trigger
    triggered = engine.update_price("AAPL", 103.0)
    assert len(triggered) == 0

    # 5% move from base — should trigger
    triggered = engine.update_price("AAPL", 105.0)
    assert len(triggered) == 1
    assert triggered[0].id == "a1"
    assert "moved" in triggered[0].message
    assert "%" in triggered[0].message


def test_pct_change_negative_move(engine):
    """Test pct_change triggers on negative moves too (uses abs value)."""
    engine.create_alert("a1", "AAPL", "pct_change", 5.0)

    # First price sets the base
    engine.update_price("AAPL", 100.0)

    # 5% drop — should trigger
    triggered = engine.update_price("AAPL", 95.0)
    assert len(triggered) == 1


def test_alert_not_triggered_below_threshold(engine):
    """Test alert is not triggered when price does not meet the condition."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)

    triggered = engine.update_price("AAPL", 199.99)
    assert len(triggered) == 0

    # Verify alert is still active
    alerts = engine.get_alerts()
    assert alerts[0].status == AlertStatus.ACTIVE


def test_already_triggered_not_re_triggered(engine):
    """Test an already-triggered alert is not triggered again."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)

    # First trigger
    triggered = engine.update_price("AAPL", 205.0)
    assert len(triggered) == 1

    # Price goes above again — should NOT re-trigger
    triggered = engine.update_price("AAPL", 210.0)
    assert len(triggered) == 0


def test_update_price_wrong_symbol(engine):
    """Test that updating a different symbol does not trigger the alert."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)

    triggered = engine.update_price("MSFT", 500.0)
    assert len(triggered) == 0


def test_update_price_returns_triggered_list(engine):
    """Test that update_price returns all newly triggered alerts."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    engine.create_alert("a2", "AAPL", "price_above", 195.0)
    engine.create_alert("a3", "MSFT", "price_above", 300.0)  # Different symbol

    triggered = engine.update_price("AAPL", 201.0)
    assert len(triggered) == 2
    triggered_ids = {a.id for a in triggered}
    assert "a1" in triggered_ids
    assert "a2" in triggered_ids
    assert "a3" not in triggered_ids


# ─── Message Format Tests ────────────────────────────────────────────

def test_build_message_price_above(engine):
    """Test message format for price_above alert."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    triggered = engine.update_price("AAPL", 205.50)

    msg = triggered[0].message
    assert "AAPL" in msg
    assert "crossed above" in msg
    assert "$200.00" in msg
    assert "$205.50" in msg


def test_build_message_price_below(engine):
    """Test message format for price_below alert."""
    engine.create_alert("a1", "TSLA", "price_below", 180.0)
    triggered = engine.update_price("TSLA", 175.25)

    msg = triggered[0].message
    assert "TSLA" in msg
    assert "dropped below" in msg
    assert "$180.00" in msg
    assert "$175.25" in msg


def test_build_message_pct_change(engine):
    """Test message format for pct_change alert."""
    engine.create_alert("a1", "NVDA", "pct_change", 5.0)
    engine.update_price("NVDA", 100.0)  # base price
    triggered = engine.update_price("NVDA", 106.0)

    msg = triggered[0].message
    assert "NVDA" in msg
    assert "moved" in msg
    assert "%" in msg
    assert "$106.00" in msg


# ─── Broadcast Tests ─────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_broadcast_triggered(engine):
    """Test that triggered alerts are broadcast via the broadcast function."""
    mock_fn = AsyncMock()
    engine.set_broadcast(mock_fn)

    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    triggered = engine.update_price("AAPL", 205.0)

    await engine.broadcast_triggered(triggered)

    mock_fn.assert_called_once()
    call_arg = mock_fn.call_args[0][0]
    assert call_arg["type"] == "alert_triggered"
    assert call_arg["payload"]["id"] == "a1"
    assert call_arg["payload"]["symbol"] == "AAPL"
    assert call_arg["payload"]["alert_type"] == "price_above"
    assert call_arg["payload"]["threshold"] == 200.0
    assert "crossed above" in call_arg["payload"]["message"]
    assert call_arg["payload"]["triggered_at"] is not None


@pytest.mark.asyncio
async def test_broadcast_triggered_no_fn(engine):
    """Test that broadcast does nothing when no broadcast function is set."""
    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    triggered = engine.update_price("AAPL", 205.0)

    # Should not raise
    await engine.broadcast_triggered(triggered)


@pytest.mark.asyncio
async def test_broadcast_triggered_empty_list(engine):
    """Test that broadcast does nothing with empty triggered list."""
    mock_fn = AsyncMock()
    engine.set_broadcast(mock_fn)

    await engine.broadcast_triggered([])

    mock_fn.assert_not_called()


@pytest.mark.asyncio
async def test_broadcast_multiple_triggered(engine):
    """Test that broadcast is called for each triggered alert."""
    mock_fn = AsyncMock()
    engine.set_broadcast(mock_fn)

    engine.create_alert("a1", "AAPL", "price_above", 200.0)
    engine.create_alert("a2", "AAPL", "price_above", 195.0)
    triggered = engine.update_price("AAPL", 201.0)

    await engine.broadcast_triggered(triggered)

    assert mock_fn.call_count == 2
