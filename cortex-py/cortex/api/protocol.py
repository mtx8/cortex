"""MessagePack-based WebSocket protocol for Swift <-> Python communication."""

from dataclasses import dataclass
from enum import IntEnum
import msgpack
import time


class MessageType(IntEnum):
    # Server -> Client (streaming)
    PORTFOLIO_UPDATE = 1
    AGENT_UPDATE = 2
    SIGNAL_FIRED = 3
    SCANNER_RESULT = 4
    ACTIVITY_EVENT = 5
    OPPORTUNITY = 6
    CHAT_TOKEN = 7
    KILL_SWITCH_STATUS = 8

    # Client -> Server (commands)
    CMD_KILL_SWITCH = 100
    CMD_DISENGAGE_KILL = 101
    CMD_SET_AUTONOMY = 102
    CMD_TOGGLE_AGENT = 103
    CMD_QUICK_TRADE = 104
    CMD_CHAT_MESSAGE = 105
    CMD_SUBSCRIBE_SCANNER = 106


@dataclass
class CortexMessage:
    type: MessageType
    payload: dict
    timestamp: float | None = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = time.time()


def encode_message(msg: CortexMessage) -> bytes:
    return msgpack.packb({
        "t": int(msg.type),
        "p": msg.payload,
        "ts": msg.timestamp,
    }, use_bin_type=True)


def decode_message(data: bytes) -> CortexMessage:
    raw = msgpack.unpackb(data, raw=False)
    return CortexMessage(
        type=MessageType(raw["t"]),
        payload=raw["p"],
        timestamp=raw["ts"],
    )
