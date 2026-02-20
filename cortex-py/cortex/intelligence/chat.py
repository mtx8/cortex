"""CortexChat — streaming Claude chat interface for the Swift UI.

This is NOT the strategic cycle (ClaudeEngine). This is the user-facing
chat interface that lets the operator ask questions about their portfolio,
market conditions, and trading strategy.

Claude is invoked on-demand by the user (not in the execution hot path).
Responses are streamed as text chunks back to the Swift client.
"""

import time
from collections import deque
from dataclasses import dataclass, field
from typing import AsyncGenerator

import structlog

from cortex.orchestrator.bus import SignalBus

log = structlog.get_logger()

_MAX_HISTORY = 20


@dataclass
class ChatMessage:
    role: str  # "user" or "assistant"
    content: str
    timestamp: float = field(default_factory=time.time)


class CortexChat:
    """Streaming Claude chat with portfolio context injection.

    Maintains per-conversation history (max 20 messages).
    Builds a system prompt with live portfolio state before each request.
    Yields text chunks as they arrive from the Claude streaming API.
    """

    def __init__(
        self,
        api_key: str,
        model: str = "claude-opus-4-6",
        bus: SignalBus | None = None,
        max_tokens: int = 2048,
    ):
        self._api_key = api_key
        self._model = model
        self._bus = bus
        self._max_tokens = max_tokens
        self._client = None  # Lazy init
        self._conversations: dict[str, deque[ChatMessage]] = {}
        self._request_count = 0
        self._error_count = 0

        # Portfolio context — updated externally before each chat turn
        self._portfolio_context: dict = {}

    def set_portfolio_context(
        self,
        nav: float = 0.0,
        daily_pnl: float = 0.0,
        positions: list[dict] | None = None,
        top_signals: list[str] | None = None,
        risk_metrics: dict | None = None,
    ) -> None:
        """Update the portfolio context injected into the system prompt."""
        self._portfolio_context = {
            "nav": nav,
            "daily_pnl": daily_pnl,
            "positions": positions or [],
            "top_signals": top_signals or [],
            "risk_metrics": risk_metrics or {},
        }

    def build_system_prompt(self, context: dict | None = None) -> str:
        """Build the system prompt with current portfolio context.

        Args:
            context: Optional UI context dict with keys like current_tab,
                     current_section, selected_symbol.
        """
        ctx = self._portfolio_context

        nav = ctx.get("nav", 0.0)
        daily_pnl = ctx.get("daily_pnl", 0.0)
        positions = ctx.get("positions", [])
        top_signals = ctx.get("top_signals", [])
        risk_metrics = ctx.get("risk_metrics", {})

        positions_text = "\n".join(
            f"  - {p.get('symbol', '?')}: {p.get('qty', 0)} shares @ ${p.get('avg_price', 0):.2f}"
            f" | P&L: ${p.get('pnl', 0):.2f}"
            for p in positions
        ) or "  (no open positions)"

        signals_text = "\n".join(
            f"  - {s}" for s in top_signals[:10]
        ) or "  (no recent signals)"

        risk_text = ""
        if risk_metrics:
            risk_text = (
                f"  - Drawdown: {risk_metrics.get('drawdown_pct', 0):.1f}%\n"
                f"  - Win Rate: {risk_metrics.get('win_rate', 0):.1%}\n"
                f"  - Sharpe: {risk_metrics.get('sharpe', 0):.2f}\n"
                f"  - Max Concurrent: {risk_metrics.get('open_positions', 0)}"
            )
        else:
            risk_text = "  (no risk data available)"

        prompt = f"""You are CORTEX AI, the intelligent assistant for an autonomous trading platform.
You help the operator understand their portfolio, market conditions, and trading strategy.

## Current Portfolio State
- NAV: ${nav:,.2f}
- Daily P&L: ${daily_pnl:+,.2f}

## Open Positions
{positions_text}

## Top Signals (recent)
{signals_text}

## Risk Metrics
{risk_text}

## Your Role
- Answer questions about the portfolio, positions, and market conditions.
- Explain trading signals and why the system generated them.
- Provide market analysis and insights when asked.
- Be concise but thorough. Use data from the context above.
- If you don't have specific data, say so rather than guessing.
- Format currency values with $ and commas. Format percentages with %.
- You are NOT executing trades. You are providing analysis and answering questions."""

        # Add UI context if provided
        if context:
            current_tab = context.get("current_tab", "unknown")
            current_section = context.get("current_section", "unknown")
            selected_symbol = context.get("selected_symbol")

            prompt += f"\n\n## Current User Context\n"
            prompt += f"The user is currently on the '{current_tab}' tab"
            if current_section != "unknown":
                prompt += f", in the '{current_section}' section"
            prompt += ".\n"

            if selected_symbol:
                prompt += f"They are looking at the symbol: {selected_symbol}\n"

            # Tab-specific context hints
            if current_tab == "scanner":
                prompt += "Focus on trading opportunities, signals, and entry/exit analysis.\n"
            elif current_tab == "financials":
                prompt += "Focus on fundamental analysis, financial metrics, news impact, and SEC filings.\n"
            elif current_tab == "war_room":
                prompt += "Focus on portfolio risk, squadron health, and overall strategy.\n"
            elif current_tab == "markets":
                prompt += "Focus on technical analysis, chart patterns, and price action.\n"
            elif current_tab == "watchlist":
                prompt += "Focus on position management, P&L, and trade monitoring.\n"

        return prompt

    async def _get_client(self):
        if self._client is None:
            try:
                import anthropic
                self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
            except ImportError:
                log.warning("anthropic SDK not installed, chat unavailable")
                self._client = None
        return self._client

    def _get_history(self, conversation_id: str) -> deque[ChatMessage]:
        if conversation_id not in self._conversations:
            self._conversations[conversation_id] = deque(maxlen=_MAX_HISTORY)
        return self._conversations[conversation_id]

    def _history_to_messages(self, conversation_id: str) -> list[dict]:
        """Convert conversation history to the Anthropic messages format."""
        history = self._get_history(conversation_id)
        return [
            {"role": msg.role, "content": msg.content}
            for msg in history
        ]

    async def stream_response(
        self,
        user_message: str,
        conversation_id: str = "default",
        context: dict | None = None,
    ) -> AsyncGenerator[str, None]:
        """Stream a response from Claude.

        Yields text chunks as they arrive. Appends both user message and
        full assistant response to conversation history.

        Args:
            user_message: The user's chat message.
            conversation_id: ID for conversation history isolation.
            context: Optional UI context (current_tab, current_section, selected_symbol).
        """
        self._request_count += 1
        history = self._get_history(conversation_id)

        # Add user message to history
        history.append(ChatMessage(role="user", content=user_message))

        client = await self._get_client()
        if client is None:
            # Fallback when anthropic SDK is unavailable
            fallback = "Chat is unavailable (Anthropic SDK not installed)."
            history.append(ChatMessage(role="assistant", content=fallback))
            yield fallback
            return

        system_prompt = self.build_system_prompt(context)
        messages = self._history_to_messages(conversation_id)

        try:
            full_response = ""
            async with client.messages.stream(
                model=self._model,
                max_tokens=self._max_tokens,
                system=system_prompt,
                messages=messages,
            ) as stream:
                async for text in stream.text_stream:
                    full_response += text
                    yield text

            # Add assistant response to history
            history.append(ChatMessage(role="assistant", content=full_response))

            log.info(
                "chat.response_complete",
                conversation_id=conversation_id,
                response_length=len(full_response),
                request_count=self._request_count,
            )

        except Exception as e:
            self._error_count += 1
            log.error(
                "chat.stream_error",
                error=str(e),
                conversation_id=conversation_id,
            )
            error_msg = f"Error generating response: {e}"
            history.append(ChatMessage(role="assistant", content=error_msg))
            yield error_msg

    def clear_conversation(self, conversation_id: str = "default") -> None:
        """Clear conversation history for a given conversation."""
        if conversation_id in self._conversations:
            del self._conversations[conversation_id]
            log.info("chat.conversation_cleared", conversation_id=conversation_id)

    def get_conversation_length(self, conversation_id: str = "default") -> int:
        history = self._conversations.get(conversation_id)
        return len(history) if history else 0

    @property
    def request_count(self) -> int:
        return self._request_count

    @property
    def error_count(self) -> int:
        return self._error_count

    def to_dict(self) -> dict:
        return {
            "model": self._model,
            "max_tokens": self._max_tokens,
            "request_count": self._request_count,
            "error_count": self._error_count,
            "active_conversations": len(self._conversations),
            "has_api_key": bool(self._api_key),
        }
