"""JSON-based WebSocket protocol for Swift <-> Python communication.

Uses orjson for fast JSON serialization. The Swift client sends and receives
plain JSON messages with keys: type, payload, ts.
"""

from dataclasses import dataclass
from enum import Enum
import time

import orjson


class MessageType(str, Enum):
    # Server -> Client (streaming)
    PORTFOLIO_UPDATE = "portfolio_update"
    AGENT_UPDATE = "agent_update"
    SIGNAL_FIRED = "signal_fired"
    SCANNER_RESULT = "scanner_result"
    ACTIVITY_EVENT = "activity_event"
    ACTIVITY = "activity"
    OPPORTUNITY = "opportunity"
    CHAT_TOKEN = "chat_token"
    KILL_SWITCH_STATUS = "kill_switch_status"
    CHAT_RESPONSE = "chat_response"
    CHAT_CHUNK = "chat_chunk"
    TICKER_SEARCH_RESULTS = "ticker_search_results"
    MARKET_QUOTE = "market_quote"
    FINANCIALS_PROFILE = "financials_profile"
    FINANCIALS_NEWS = "financials_news"
    FINANCIALS_FILINGS = "financials_filings"
    FINANCIALS_SENTIMENT = "financials_sentiment"
    FINANCIALS_AI_ANALYSIS = "financials_ai_analysis"

    # Client -> Server (commands)
    CMD_KILL_SWITCH = "cmd_kill_switch"
    CMD_DISENGAGE_KILL = "cmd_disengage_kill"
    CMD_SET_AUTONOMY = "cmd_set_autonomy"
    CMD_TOGGLE_AGENT = "cmd_toggle_agent"
    CMD_QUICK_TRADE = "cmd_quick_trade"
    CMD_CHAT_MESSAGE = "cmd_chat_message"
    CMD_SUBSCRIBE_SCANNER = "cmd_subscribe_scanner"
    CMD_SEARCH_TICKER = "cmd_search_ticker"
    CMD_REQUEST_QUOTES = "cmd_request_quotes"
    CMD_FINANCIALS_LOOKUP = "cmd_financials_lookup"
    CMD_CONNECT_IBKR = "cmd_connect_ibkr"


@dataclass
class CortexMessage:
    type: MessageType
    payload: dict
    timestamp: float | None = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = time.time()


def encode_message(msg: CortexMessage) -> str:
    """Encode a CortexMessage to a JSON string using orjson."""
    return orjson.dumps({
        "type": msg.type.value,
        "payload": msg.payload,
        "ts": msg.timestamp,
    }).decode("utf-8")


def decode_message(data: dict) -> CortexMessage:
    """Decode a dict (already parsed by FastAPI/orjson) into a CortexMessage.

    Accepts dicts with keys: type, payload, ts.
    """
    return CortexMessage(
        type=MessageType(data["type"]),
        payload=data.get("payload", {}),
        timestamp=data.get("ts"),
    )
