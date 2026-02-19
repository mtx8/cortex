"""Audit Trail — logs every signal, order, fill, and risk decision.
Provides complete traceability from signal source to execution.

All entries are written to PostgreSQL audit_trail table.
In-memory buffer + async batch flush for performance.
"""

import asyncio
import time
import uuid
from dataclasses import dataclass, field
from collections import deque
from enum import Enum
import structlog

log = structlog.get_logger()


class AuditEventType(str, Enum):
    SIGNAL_EMITTED = "signal_emitted"
    SIGNAL_RECEIVED = "signal_received"
    RISK_CHECK_PASSED = "risk_check_passed"
    RISK_CHECK_FAILED = "risk_check_failed"
    ORDER_SUBMITTED = "order_submitted"
    ORDER_FILLED = "order_filled"
    ORDER_REJECTED = "order_rejected"
    ORDER_CANCELLED = "order_cancelled"
    KILL_SWITCH_ENGAGED = "kill_switch_engaged"
    KILL_SWITCH_DISENGAGED = "kill_switch_disengaged"
    DRAWDOWN_WARNING = "drawdown_warning"
    DRAWDOWN_HALT = "drawdown_halt"
    POSITION_SIZED = "position_sized"
    AGENT_ERROR = "agent_error"


@dataclass
class AuditEntry:
    event_id: str
    event_type: AuditEventType
    source_agent: str
    source_squadron: str
    timestamp: float = field(default_factory=time.time)
    triggered_by_event_id: str | None = None
    signal_payload: dict | None = None
    trade_id: str | None = None
    symbol: str | None = None
    message: str = ""

    def to_dict(self) -> dict:
        return {
            "event_id": self.event_id,
            "event_type": self.event_type.value,
            "source_agent": self.source_agent,
            "source_squadron": self.source_squadron,
            "timestamp": self.timestamp,
            "triggered_by_event_id": self.triggered_by_event_id,
            "signal_payload": self.signal_payload,
            "trade_id": self.trade_id,
            "symbol": self.symbol,
            "message": self.message,
        }


class AuditTrail:
    """In-memory audit trail with batch flush to PostgreSQL.
    Thread-safe via asyncio."""

    def __init__(self, buffer_size: int = 1000, flush_interval: float = 5.0):
        self._buffer: deque[AuditEntry] = deque(maxlen=buffer_size)
        self._flush_interval = flush_interval
        self._total_entries = 0
        self._flushed_entries = 0
        self._db_writer = None  # Will be set when DB is available

    def log(
        self,
        event_type: AuditEventType,
        source_agent: str,
        source_squadron: str,
        triggered_by: str | None = None,
        payload: dict | None = None,
        trade_id: str | None = None,
        symbol: str | None = None,
        message: str = "",
    ) -> str:
        """Log an audit event. Returns the event_id."""
        event_id = str(uuid.uuid4())
        entry = AuditEntry(
            event_id=event_id,
            event_type=event_type,
            source_agent=source_agent,
            source_squadron=source_squadron,
            triggered_by_event_id=triggered_by,
            signal_payload=payload,
            trade_id=trade_id,
            symbol=symbol,
            message=message,
        )
        self._buffer.append(entry)
        self._total_entries += 1

        log.debug(
            "audit.logged",
            event_type=event_type.value,
            source_agent=source_agent,
            symbol=symbol,
        )

        return event_id

    def log_signal(
        self,
        signal_type: str,
        source_agent: str,
        source_squadron: str,
        payload: dict | None = None,
        symbol: str | None = None,
    ) -> str:
        return self.log(
            event_type=AuditEventType.SIGNAL_EMITTED,
            source_agent=source_agent,
            source_squadron=source_squadron,
            payload=payload,
            symbol=symbol,
            message=f"Signal: {signal_type}",
        )

    def log_order(
        self,
        event_type: AuditEventType,
        source_agent: str,
        order_id: str,
        symbol: str,
        triggered_by: str | None = None,
        message: str = "",
    ) -> str:
        return self.log(
            event_type=event_type,
            source_agent=source_agent,
            source_squadron="bravo",
            trade_id=order_id,
            symbol=symbol,
            triggered_by=triggered_by,
            message=message,
        )

    def log_risk_decision(
        self,
        approved: bool,
        source_agent: str,
        symbol: str,
        rejections: list[str] | None = None,
        triggered_by: str | None = None,
    ) -> str:
        event_type = AuditEventType.RISK_CHECK_PASSED if approved else AuditEventType.RISK_CHECK_FAILED
        message = "Approved" if approved else f"Rejected: {', '.join(rejections or [])}"
        return self.log(
            event_type=event_type,
            source_agent=source_agent,
            source_squadron="echo",
            symbol=symbol,
            triggered_by=triggered_by,
            message=message,
        )

    def get_recent(self, count: int = 50) -> list[AuditEntry]:
        """Get most recent audit entries from buffer."""
        entries = list(self._buffer)
        return entries[-count:]

    def get_by_symbol(self, symbol: str) -> list[AuditEntry]:
        return [e for e in self._buffer if e.symbol == symbol]

    def get_by_trade(self, trade_id: str) -> list[AuditEntry]:
        return [e for e in self._buffer if e.trade_id == trade_id]

    async def flush_to_db(self) -> int:
        """Flush buffered entries to PostgreSQL. Returns count flushed.
        Placeholder — actual DB write requires asyncpg connection."""
        if not self._buffer:
            return 0

        entries = list(self._buffer)
        self._buffer.clear()

        # TODO: Actual asyncpg INSERT when DB is connected
        # async with self._pool.acquire() as conn:
        #     await conn.executemany(INSERT_SQL, [e.to_dict() for e in entries])

        count = len(entries)
        self._flushed_entries += count
        log.info("audit.flushed", count=count, total=self._flushed_entries)
        return count

    @property
    def total_entries(self) -> int:
        return self._total_entries

    @property
    def buffer_size(self) -> int:
        return len(self._buffer)

    @property
    def flushed_entries(self) -> int:
        return self._flushed_entries

    def to_dict(self) -> dict:
        return {
            "total_entries": self._total_entries,
            "buffer_size": self.buffer_size,
            "flushed_entries": self._flushed_entries,
        }
