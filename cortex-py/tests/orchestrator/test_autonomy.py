import pytest
from cortex.orchestrator.autonomy import (
    AutonomyLevel, AutonomyDial, ActionGate,
)


def test_autonomy_levels():
    assert AutonomyLevel.FULL_MANUAL.value == 0
    assert AutonomyLevel.SUGGEST_ONLY.value == 1
    assert AutonomyLevel.SEMI_AUTO.value == 2
    assert AutonomyLevel.FULL_AUTO.value == 3


def test_default_level():
    dial = AutonomyDial()
    assert dial.level == AutonomyLevel.SUGGEST_ONLY


def test_set_level():
    dial = AutonomyDial()
    dial.set_level(AutonomyLevel.FULL_AUTO)
    assert dial.level == AutonomyLevel.FULL_AUTO


def test_gate_full_manual_blocks_all():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is False
    assert gate.requires_approval is True


def test_gate_suggest_only_requires_approval():
    dial = AutonomyDial(level=AutonomyLevel.SUGGEST_ONLY)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is True
    assert gate.requires_approval is True


def test_gate_semi_auto_small_trade():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=300.0)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_gate_semi_auto_large_trade():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=300.0)
    gate = dial.check("alpha.entry_signal", notional=400.0)
    assert gate.allowed is True
    assert gate.requires_approval is True


def test_gate_full_auto_allows_all():
    dial = AutonomyDial(level=AutonomyLevel.FULL_AUTO)
    gate = dial.check("alpha.entry_signal", notional=500.0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_kill_switch_always_allowed():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("echo.kill_switch", notional=0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_risk_breach_always_allowed():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("echo.risk_breach", notional=0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_to_dict():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=250.0)
    d = dial.to_dict()
    assert d["level"] == "semi_auto"
    assert d["auto_threshold"] == 250.0


def test_history_tracking():
    dial = AutonomyDial(level=AutonomyLevel.FULL_AUTO)
    dial.check("alpha.entry_signal", notional=100.0)
    dial.check("alpha.entry_signal", notional=200.0)
    assert dial.checks_today == 2
    assert dial.auto_approved_today == 2
