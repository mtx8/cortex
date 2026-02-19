import pytest
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.api.protocol import MessageType, CortexMessage, encode_message, decode_message
from cortex.orchestrator.bus import SignalBus


def test_broadcaster_creation():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    assert bc.client_count == 0


def test_build_portfolio_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_portfolio_message(
        nav=100000, daily_pnl=500, total_pnl=5000,
        win_rate=0.6, open_positions=3,
    )
    assert msg.type == MessageType.PORTFOLIO_UPDATE
    assert msg.payload["nav"] == 100000


def test_build_agent_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_agent_message(
        agent_id="signal_hunter", squadron="alpha",
        status="active", signal_count=42, error_count=0,
    )
    assert msg.type == MessageType.AGENT_UPDATE
    assert msg.payload["agent_id"] == "signal_hunter"


def test_build_signal_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_signal_message(
        signal_type="alpha.entry_signal",
        source_agent="signal_hunter",
        symbol="AAPL",
        payload={"confidence": 0.85},
    )
    assert msg.type == MessageType.SIGNAL_FIRED


def test_build_kill_switch_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_kill_switch_message(active=True, reason="manual")
    assert msg.type == MessageType.KILL_SWITCH_STATUS
    assert msg.payload["active"] is True


def test_encode_decode_roundtrip():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_portfolio_message(
        nav=50000, daily_pnl=-200, total_pnl=1000,
        win_rate=0.55, open_positions=2,
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.type == MessageType.PORTFOLIO_UPDATE
    assert decoded.payload["nav"] == 50000
