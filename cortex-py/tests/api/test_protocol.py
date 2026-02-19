import pytest
import msgpack
from cortex.api.protocol import CortexMessage, MessageType, encode_message, decode_message


def test_encode_decode_roundtrip():
    msg = CortexMessage(
        type=MessageType.PORTFOLIO_UPDATE,
        payload={"nav": 50000.0, "daily_pnl": 150.0},
    )
    encoded = encode_message(msg)
    assert isinstance(encoded, bytes)

    decoded = decode_message(encoded)
    assert decoded.type == MessageType.PORTFOLIO_UPDATE
    assert decoded.payload["nav"] == 50000.0


def test_kill_switch_command():
    msg = CortexMessage(
        type=MessageType.CMD_KILL_SWITCH,
        payload={"reason": "manual"},
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.type == MessageType.CMD_KILL_SWITCH


def test_agent_update_message():
    msg = CortexMessage(
        type=MessageType.AGENT_UPDATE,
        payload={
            "agent_id": "signal_hunter",
            "status": "active",
            "signal_count": 42,
        },
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.payload["agent_id"] == "signal_hunter"
