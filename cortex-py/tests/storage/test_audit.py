import pytest
from cortex.storage.audit import AuditTrail, AuditEventType, AuditEntry


def test_log_returns_event_id():
    trail = AuditTrail()
    event_id = trail.log(
        event_type=AuditEventType.SIGNAL_EMITTED,
        source_agent="signal_hunter",
        source_squadron="alpha",
        symbol="AAPL",
    )
    assert event_id is not None
    assert len(event_id) > 0


def test_log_increments_counter():
    trail = AuditTrail()
    assert trail.total_entries == 0
    trail.log(AuditEventType.SIGNAL_EMITTED, "test", "test")
    trail.log(AuditEventType.ORDER_SUBMITTED, "test", "bravo")
    assert trail.total_entries == 2


def test_get_recent():
    trail = AuditTrail()
    for i in range(10):
        trail.log(AuditEventType.SIGNAL_EMITTED, f"agent_{i}", "alpha")
    recent = trail.get_recent(5)
    assert len(recent) == 5


def test_get_by_symbol():
    trail = AuditTrail()
    trail.log(AuditEventType.SIGNAL_EMITTED, "test", "alpha", symbol="AAPL")
    trail.log(AuditEventType.SIGNAL_EMITTED, "test", "alpha", symbol="MSFT")
    trail.log(AuditEventType.ORDER_FILLED, "sniper", "bravo", symbol="AAPL")

    aapl = trail.get_by_symbol("AAPL")
    assert len(aapl) == 2
    assert all(e.symbol == "AAPL" for e in aapl)


def test_get_by_trade():
    trail = AuditTrail()
    trail.log_order(AuditEventType.ORDER_SUBMITTED, "sniper", "ORD-001", "AAPL")
    trail.log_order(AuditEventType.ORDER_FILLED, "sniper", "ORD-001", "AAPL")
    trail.log_order(AuditEventType.ORDER_SUBMITTED, "sniper", "ORD-002", "MSFT")

    ord1 = trail.get_by_trade("ORD-001")
    assert len(ord1) == 2


def test_log_signal():
    trail = AuditTrail()
    event_id = trail.log_signal(
        signal_type="alpha.entry_signal",
        source_agent="signal_hunter",
        source_squadron="alpha",
        payload={"symbol": "AAPL", "confidence": 0.85},
        symbol="AAPL",
    )
    entries = trail.get_recent(1)
    assert entries[0].event_type == AuditEventType.SIGNAL_EMITTED
    assert "entry_signal" in entries[0].message


def test_log_risk_decision_approved():
    trail = AuditTrail()
    trail.log_risk_decision(
        approved=True,
        source_agent="risk_guardian",
        symbol="AAPL",
    )
    entries = trail.get_recent(1)
    assert entries[0].event_type == AuditEventType.RISK_CHECK_PASSED
    assert "Approved" in entries[0].message


def test_log_risk_decision_rejected():
    trail = AuditTrail()
    trail.log_risk_decision(
        approved=False,
        source_agent="risk_guardian",
        symbol="TSLA",
        rejections=["Position too large", "Max drawdown hit"],
    )
    entries = trail.get_recent(1)
    assert entries[0].event_type == AuditEventType.RISK_CHECK_FAILED
    assert "Position too large" in entries[0].message


@pytest.mark.asyncio
async def test_flush_clears_buffer():
    trail = AuditTrail()
    trail.log(AuditEventType.SIGNAL_EMITTED, "test", "test")
    trail.log(AuditEventType.ORDER_SUBMITTED, "test", "bravo")
    assert trail.buffer_size == 2

    flushed = await trail.flush_to_db()
    assert flushed == 2
    assert trail.buffer_size == 0
    assert trail.flushed_entries == 2


def test_buffer_max_size():
    trail = AuditTrail(buffer_size=5)
    for i in range(10):
        trail.log(AuditEventType.SIGNAL_EMITTED, "test", "test")
    assert trail.buffer_size == 5
    assert trail.total_entries == 10


def test_audit_entry_to_dict():
    trail = AuditTrail()
    trail.log(
        AuditEventType.KILL_SWITCH_ENGAGED,
        "kill_switch_commander",
        "echo",
        symbol=None,
        message="Manual kill switch",
    )
    entry = trail.get_recent(1)[0]
    d = entry.to_dict()
    assert d["event_type"] == "kill_switch_engaged"
    assert d["source_agent"] == "kill_switch_commander"


def test_to_dict():
    trail = AuditTrail()
    trail.log(AuditEventType.SIGNAL_EMITTED, "test", "test")
    d = trail.to_dict()
    assert d["total_entries"] == 1
    assert d["buffer_size"] == 1
    assert d["flushed_entries"] == 0
