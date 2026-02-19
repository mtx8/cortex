"""AutonomyDial — controls how much human oversight CORTEX requires.

Four levels from FULL_MANUAL (everything blocked without approval) to
FULL_AUTO (system trades independently).  Safety signals (kill_switch,
risk_breach) ALWAYS bypass the dial — they are never blocked."""

from dataclasses import dataclass
from enum import IntEnum

import structlog

log = structlog.get_logger()

# ── Signal substrings that ALWAYS bypass the autonomy gate ──────────
_SAFETY_OVERRIDES = ("kill_switch", "risk_breach")


class AutonomyLevel(IntEnum):
    FULL_MANUAL = 0   # Everything requires human approval
    SUGGEST_ONLY = 1  # System suggests, human confirms
    SEMI_AUTO = 2     # Auto below threshold, approval above
    FULL_AUTO = 3     # System trades independently


@dataclass(slots=True)
class ActionGate:
    """Result of an autonomy check."""
    allowed: bool
    requires_approval: bool
    reason: str


class AutonomyDial:
    """Central dial that gates every actionable signal in CORTEX."""

    def __init__(
        self,
        level: AutonomyLevel = AutonomyLevel.SUGGEST_ONLY,
        auto_threshold: float = 250.0,
    ) -> None:
        self._level = level
        self._auto_threshold = auto_threshold
        self._checks_today: int = 0
        self._auto_approved_today: int = 0
        log.info(
            "autonomy.init",
            level=level.name,
            auto_threshold=auto_threshold,
        )

    # ── Properties ──────────────────────────────────────────────────

    @property
    def level(self) -> AutonomyLevel:
        return self._level

    @property
    def auto_threshold(self) -> float:
        return self._auto_threshold

    @property
    def checks_today(self) -> int:
        return self._checks_today

    @property
    def auto_approved_today(self) -> int:
        return self._auto_approved_today

    # ── Mutators ────────────────────────────────────────────────────

    def set_level(self, level: AutonomyLevel) -> None:
        old = self._level
        self._level = level
        log.info("autonomy.level_changed", old=old.name, new=level.name)

    def reset_daily(self) -> None:
        """Reset daily counters — called at start of each trading day."""
        self._checks_today = 0
        self._auto_approved_today = 0
        log.info("autonomy.daily_reset")

    # ── Core gate logic ─────────────────────────────────────────────

    def check(self, signal_type: str, notional: float) -> ActionGate:
        """Gate an action based on current autonomy level.

        Safety overrides: kill_switch and risk_breach signals are ALWAYS
        allowed without approval, regardless of autonomy level.
        """
        self._checks_today += 1

        # Safety overrides — never blocked
        if any(override in signal_type for override in _SAFETY_OVERRIDES):
            self._auto_approved_today += 1
            log.info(
                "autonomy.safety_override",
                signal_type=signal_type,
                notional=notional,
            )
            return ActionGate(
                allowed=True,
                requires_approval=False,
                reason="safety_override",
            )

        gate = self._evaluate(signal_type, notional)

        if gate.allowed and not gate.requires_approval:
            self._auto_approved_today += 1

        log.info(
            "autonomy.check",
            signal_type=signal_type,
            notional=notional,
            level=self._level.name,
            allowed=gate.allowed,
            requires_approval=gate.requires_approval,
            reason=gate.reason,
        )
        return gate

    def _evaluate(self, signal_type: str, notional: float) -> ActionGate:
        """Pure decision logic — no side effects."""
        if self._level == AutonomyLevel.FULL_MANUAL:
            return ActionGate(
                allowed=False,
                requires_approval=True,
                reason="full_manual_mode",
            )

        if self._level == AutonomyLevel.SUGGEST_ONLY:
            return ActionGate(
                allowed=True,
                requires_approval=True,
                reason="suggest_only_mode",
            )

        if self._level == AutonomyLevel.SEMI_AUTO:
            over_threshold = notional > self._auto_threshold
            return ActionGate(
                allowed=True,
                requires_approval=over_threshold,
                reason="over_threshold" if over_threshold else "under_threshold",
            )

        # FULL_AUTO
        return ActionGate(
            allowed=True,
            requires_approval=False,
            reason="full_auto_mode",
        )

    # ── Serialisation ───────────────────────────────────────────────

    def to_dict(self) -> dict:
        return {
            "level": self._level.name.lower(),
            "auto_threshold": self._auto_threshold,
            "checks_today": self._checks_today,
            "auto_approved_today": self._auto_approved_today,
        }
