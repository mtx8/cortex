"""Claude Intelligence Engine -- strategic AI cycle for CORTEX.

Runs every N seconds (default 300), analyzes portfolio state,
and emits strategy_update signals to guide agent behavior.

RULE: Claude is NEVER in the execution hot path. Strategic cycle only.
"""

import json
import time
from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.intelligence.prompts import build_strategic_prompt

log = structlog.get_logger()


@dataclass
class StrategyDecision:
    market_regime: str
    sector_focus: list[str]
    risk_appetite: float
    signals_to_amplify: list[str]
    signals_to_suppress: list[str]
    reasoning: str
    timestamp: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {
            "market_regime": self.market_regime,
            "sector_focus": self.sector_focus,
            "risk_appetite": self.risk_appetite,
            "signals_to_amplify": self.signals_to_amplify,
            "signals_to_suppress": self.signals_to_suppress,
            "reasoning": self.reasoning,
            "timestamp": self.timestamp,
        }


class ClaudeEngine:
    """Strategic intelligence cycle using Claude API.
    NOT in the execution hot path -- runs on a timer."""

    def __init__(
        self,
        bus: SignalBus,
        api_key: str,
        model: str = "claude-sonnet-4-6",
        cycle_seconds: int = 300,
        max_tokens: int = 1024,
    ):
        self._bus = bus
        self._api_key = api_key
        self._model = model
        self.cycle_seconds = cycle_seconds
        self._max_tokens = max_tokens
        self._last_decision: StrategyDecision | None = None
        self._cycle_count = 0
        self._error_count = 0
        self._client = None  # Lazy init

    async def _get_client(self):
        if self._client is None:
            try:
                import anthropic
                self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
            except ImportError:
                log.warning("anthropic SDK not installed, using mock mode")
                self._client = None
        return self._client

    async def _call_claude(self, prompt: str):
        client = await self._get_client()
        if client is None:
            return None
        return await client.messages.create(
            model=self._model,
            max_tokens=self._max_tokens,
            messages=[{"role": "user", "content": prompt}],
        )

    async def run_strategic_cycle(
        self,
        nav: float,
        daily_pnl: float,
        positions: list[dict],
        recent_signals: list[str],
        drawdown_pct: float,
        win_rate: float,
    ) -> StrategyDecision | None:
        """Execute one strategic cycle. Returns decision or None on error."""
        self._cycle_count += 1

        prompt = build_strategic_prompt(
            nav=nav, daily_pnl=daily_pnl, positions=positions,
            recent_signals=recent_signals, drawdown_pct=drawdown_pct,
            win_rate=win_rate,
        )

        try:
            response = await self._call_claude(prompt)
            if response is None:
                return None

            text = response.content[0].text
            data = json.loads(text)

            decision = StrategyDecision(
                market_regime=data.get("market_regime", "neutral"),
                sector_focus=data.get("sector_focus", []),
                risk_appetite=float(data.get("risk_appetite", 0.5)),
                signals_to_amplify=data.get("signals_to_amplify", []),
                signals_to_suppress=data.get("signals_to_suppress", []),
                reasoning=data.get("reasoning", ""),
            )

            self._last_decision = decision

            await self._bus.publish(Signal(
                signal_id=f"claude_strategy_{self._cycle_count}",
                source_agent="claude_engine",
                source_squadron="intelligence",
                signal_type=SignalTypes.STRATEGY_UPDATE,
                payload=decision.to_dict(),
                priority=SignalPriority.LOW,
            ))

            log.info(
                "claude.strategy_update",
                regime=decision.market_regime,
                risk_appetite=decision.risk_appetite,
                cycle=self._cycle_count,
            )

            return decision

        except Exception as e:
            self._error_count += 1
            log.error("claude.cycle_error", error=str(e), cycle=self._cycle_count)
            return None

    @property
    def last_decision(self) -> StrategyDecision | None:
        return self._last_decision

    def to_dict(self) -> dict:
        return {
            "cycle_count": self._cycle_count,
            "error_count": self._error_count,
            "model": self._model,
            "cycle_seconds": self.cycle_seconds,
            "last_decision": self._last_decision.to_dict() if self._last_decision else None,
        }
