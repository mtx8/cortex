import pytest
import orjson
from cortex.api.protocol import CortexMessage, MessageType, encode_message, decode_message


def test_encode_returns_json_string():
    msg = CortexMessage(
        type=MessageType.PORTFOLIO_UPDATE,
        payload={"nav": 50000.0, "daily_pnl": 150.0},
    )
    encoded = encode_message(msg)
    assert isinstance(encoded, str)
    parsed = orjson.loads(encoded)
    assert parsed["type"] == "portfolio_update"
    assert parsed["payload"]["nav"] == 50000.0
    assert "ts" in parsed


def test_decode_from_dict():
    data = {
        "type": "portfolio_update",
        "payload": {"nav": 50000.0, "daily_pnl": 150.0},
        "ts": 1700000000.0,
    }
    msg = decode_message(data)
    assert msg.type == MessageType.PORTFOLIO_UPDATE
    assert msg.payload["nav"] == 50000.0
    assert msg.timestamp == 1700000000.0


def test_encode_decode_roundtrip():
    msg = CortexMessage(
        type=MessageType.PORTFOLIO_UPDATE,
        payload={"nav": 50000.0, "daily_pnl": 150.0},
    )
    encoded = encode_message(msg)
    parsed = orjson.loads(encoded)
    decoded = decode_message(parsed)
    assert decoded.type == MessageType.PORTFOLIO_UPDATE
    assert decoded.payload["nav"] == 50000.0


def test_kill_switch_command():
    msg = CortexMessage(
        type=MessageType.CMD_KILL_SWITCH,
        payload={"reason": "manual"},
    )
    encoded = encode_message(msg)
    parsed = orjson.loads(encoded)
    decoded = decode_message(parsed)
    assert decoded.type == MessageType.CMD_KILL_SWITCH
    assert decoded.payload["reason"] == "manual"


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
    parsed = orjson.loads(encoded)
    decoded = decode_message(parsed)
    assert decoded.payload["agent_id"] == "signal_hunter"


def test_message_type_string_values():
    assert MessageType.PORTFOLIO_UPDATE.value == "portfolio_update"
    assert MessageType.CMD_KILL_SWITCH.value == "cmd_kill_switch"
    assert MessageType.CHAT_CHUNK.value == "chat_chunk"
    assert MessageType.MARKET_QUOTE.value == "market_quote"
    assert MessageType.CMD_SEARCH_TICKER.value == "cmd_search_ticker"


def test_new_message_types_exist():
    assert MessageType.CHAT_RESPONSE == "chat_response"
    assert MessageType.CHAT_CHUNK == "chat_chunk"
    assert MessageType.TICKER_SEARCH_RESULTS == "ticker_search_results"
    assert MessageType.MARKET_QUOTE == "market_quote"
    assert MessageType.CMD_SEARCH_TICKER == "cmd_search_ticker"
    assert MessageType.CMD_REQUEST_QUOTES == "cmd_request_quotes"


def test_decode_missing_ts_defaults():
    data = {
        "type": "agent_update",
        "payload": {"agent_id": "test"},
    }
    msg = decode_message(data)
    assert msg.type == MessageType.AGENT_UPDATE
    assert msg.timestamp is not None  # auto-generated


def test_chat_chunk_message():
    msg = CortexMessage(
        type=MessageType.CHAT_CHUNK,
        payload={"chunk": "Hello", "done": False, "conversation_id": "abc"},
    )
    encoded = encode_message(msg)
    parsed = orjson.loads(encoded)
    assert parsed["type"] == "chat_chunk"
    assert parsed["payload"]["chunk"] == "Hello"


def test_market_quote_message():
    msg = CortexMessage(
        type=MessageType.MARKET_QUOTE,
        payload={"symbol": "AAPL", "price": 185.50, "change_pct": 1.25},
    )
    encoded = encode_message(msg)
    parsed = orjson.loads(encoded)
    assert parsed["type"] == "market_quote"
    assert parsed["payload"]["symbol"] == "AAPL"
