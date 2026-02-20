"""CortexChat — streaming Claude chat interface for the Swift UI.

This is NOT the strategic cycle (ClaudeEngine). This is the user-facing
chat interface that lets the operator ask questions about their portfolio,
market conditions, and trading strategy.

Claude is invoked on-demand by the user (not in the execution hot path).
Responses are streamed as text chunks back to the Swift client.
"""

import asyncio
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
        max_tokens: int = 4096,
    ):
        self._api_key = api_key
        self._model = model
        self._fallback_model = "claude-sonnet-4-6"
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
        """Build the system prompt with live platform data.

        Args:
            context: Enriched context dict with portfolio, scanner_opportunities,
                     agents, market_quotes, kill_switch, current_tab, current_section,
                     selected_symbol. Populated by _build_enriched_context() in main.py.
        """
        ctx = context or {}

        # ── Portfolio KPIs: enriched context > set_portfolio_context > defaults ──
        portfolio = ctx.get("portfolio") or {}
        pc = self._portfolio_context or {}

        nav = portfolio.get("nav", pc.get("nav", 0.0))
        daily_pnl = portfolio.get("daily_pnl", pc.get("daily_pnl", 0.0))
        total_pnl = portfolio.get("total_pnl", 0.0)
        win_rate_val = portfolio.get("win_rate", 0.0)
        sharpe_val = portfolio.get("sharpe_ratio", 0.0)
        buying_power = portfolio.get("buying_power", 0.0)
        open_pos = portfolio.get("open_positions", 0)

        # ── Positions (from set_portfolio_context — backward compat) ──
        positions = pc.get("positions", [])
        positions_text = "\n".join(
            f"  - {p.get('symbol', '?')}: {p.get('qty', 0)} shares @ ${p.get('avg_price', 0):.2f}"
            f" | P&L: ${p.get('pnl', 0):.2f}"
            for p in positions
        ) or "  (no open positions)"

        # ── Top Signals (from set_portfolio_context — backward compat) ──
        top_signals = pc.get("top_signals", [])
        signals_text = "\n".join(
            f"  - {s}" for s in top_signals[:10]
        ) or "  (no recent signals)"

        # ── Risk Metrics (from set_portfolio_context — backward compat) ──
        risk_metrics = pc.get("risk_metrics", {})
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

        # ── Extra portfolio lines (from enriched context) ──
        portfolio_extra = ""
        extra_parts = []
        if total_pnl:
            extra_parts.append(f"Total P&L: ${total_pnl:+,.2f}")
        if win_rate_val:
            extra_parts.append(f"Win Rate: {win_rate_val:.1%}")
        if sharpe_val:
            extra_parts.append(f"Sharpe: {sharpe_val:.2f}")
        if buying_power:
            extra_parts.append(f"Buying Power: ${buying_power:,.2f}")
        if open_pos:
            extra_parts.append(f"Open Positions: {open_pos}")
        if extra_parts:
            portfolio_extra = "\n- " + "\n- ".join(extra_parts)

        # ── Kill Switch (from enriched context) ──
        ks = ctx.get("kill_switch") or {}
        ks_section = ""
        if ks.get("active"):
            ks_section = (
                f"\n\n## KILL SWITCH ACTIVE\n"
                f"All trading is HALTED. Reason: {ks.get('reason', 'unknown')}\n"
                f"No new orders can be placed until the kill switch is disengaged."
            )

        # ── Scanner Opportunities (from enriched context) ──
        scanner_opps = ctx.get("scanner_opportunities", [])
        scanner_section = ""
        if scanner_opps:
            lines = []
            for opp in scanner_opps[:15]:
                t = opp.get("ticker", "?")
                s = opp.get("score", 0)
                ot = opp.get("type", "?")
                d = opp.get("direction", "long").upper()
                rr = opp.get("risk_reward", 0)
                thesis = opp.get("thesis", "")
                lines.append(
                    f"  - {t}: Score {s:.1f} | {ot} | {d} | R:R {rr:.1f} | {thesis}"
                )
            scanner_section = (
                f"\n\n## Active Scanner Results ({len(scanner_opps)} opportunities)\n"
                + "\n".join(lines)
            )

        # ── Agent/Squadron Health (from enriched context) ──
        agents = ctx.get("agents", [])
        agents_section = ""
        if agents:
            by_sq: dict[str, list[dict]] = {}
            for a in agents:
                sq = a.get("squadron", "unknown")
                by_sq.setdefault(sq, []).append(a)
            lines = []
            for sq, ags in sorted(by_sq.items()):
                active = sum(1 for a in ags if a.get("status") == "active")
                sigs = sum(a.get("signal_count", 0) for a in ags)
                errs = sum(a.get("error_count", 0) for a in ags)
                names = ", ".join(a.get("id", "?") for a in ags)
                lines.append(
                    f"  - {sq.upper()}: {active}/{len(ags)} active | "
                    f"{sigs} signals | {errs} errors | Agents: {names}"
                )
            agents_section = (
                f"\n\n## Squadron Health ({len(agents)} agents)\n"
                + "\n".join(lines)
            )

        # ── Market Quotes (from enriched context) ──
        quotes = ctx.get("market_quotes") or {}
        quotes_section = ""
        if quotes:
            lines = []
            for ticker, q in sorted(quotes.items()):
                price = q.get("price", 0)
                change = q.get("change", 0)
                cpct = q.get("change_pct", 0)
                sign = "+" if change >= 0 else ""
                lines.append(
                    f"  - {ticker}: ${price:,.2f} ({sign}{change:.2f}, {sign}{cpct:.2f}%)"
                )
            quotes_section = f"\n\n## Live Market Quotes\n" + "\n".join(lines)

        # ── Assemble prompt ──
        prompt = f"""You are CORTEX AI, the intelligent command assistant for an autonomous trading platform.
You have LIVE access to real-time platform data. Use the data below for specific, data-driven analysis.

## Current Portfolio State
- NAV: ${nav:,.2f}
- Daily P&L: ${daily_pnl:+,.2f}{portfolio_extra}

## Open Positions
{positions_text}

## Top Signals (recent)
{signals_text}

## Risk Metrics
{risk_text}{ks_section}{scanner_section}{agents_section}{quotes_section}

## Your Role
- Answer questions about the portfolio, positions, and market conditions.
- When discussing scanner results, reference specific scores, types, and theses from the data above.
- When discussing risk or strategy, reference portfolio NAV, P&L, and squadron health.
- Provide specific, actionable analysis. Use ONLY the data shown above — never invent numbers.
- Be concise but thorough. Use data from the context above.
- If you don't have specific data, say so rather than guessing.
- Format currency values with $ and commas. Format percentages with %.
- When on Trade view, focus on execution quality, slippage, order types, and Level 2 depth analysis.
- When in Simulation mode, discuss pattern learning, strategy backtesting, and performance optimization.
- You are NOT executing trades. You are providing analysis and answering questions."""

        # ── UI context hints ──
        if ctx and (ctx.get("current_tab") or ctx.get("selected_symbol")):
            current_tab = ctx.get("current_tab", "unknown")
            current_section = ctx.get("current_section", "unknown")
            selected_symbol = ctx.get("selected_symbol")

            prompt += f"\n\n## Current User Context\n"
            prompt += f"The user is currently on the '{current_tab}' tab"
            if current_section != "unknown":
                prompt += f", in the '{current_section}' section"
            prompt += ".\n"

            if selected_symbol:
                prompt += f"They are looking at the symbol: {selected_symbol}\n"

            # Normalize tab name for matching (handles "War Room", "war_room", etc.)
            tab = current_tab.lower().replace(" ", "_")

            if tab == "scanner":
                prompt += (
                    "Focus on trading opportunities, signals, and entry/exit analysis. "
                    "Reference the scanner results above with specific scores, theses, and R:R ratios.\n"
                )
            elif tab == "financials":
                prompt += "Focus on fundamental analysis, financial metrics, news impact, and SEC filings.\n"
            elif tab in ("war_room", "warroom"):
                prompt += (
                    "Focus on portfolio risk, squadron health, and overall strategy. "
                    "Reference the portfolio metrics and agent health data above.\n"
                )
            elif tab == "markets":
                prompt += (
                    "Focus on technical analysis, chart patterns, and price action. "
                    "Reference the live market quotes above.\n"
                )
            elif tab == "watchlist":
                prompt += "Focus on position management, P&L, and trade monitoring.\n"
            elif tab == "squadrons":
                prompt += (
                    "Focus on agent performance, squadron health, signal throughput, and operations. "
                    "Reference the squadron health data above.\n"
                )
            elif tab == "performance":
                prompt += "Focus on performance analytics, risk-adjusted returns, and trade statistics.\n"
            elif tab == "trade":
                prompt += (
                    "Focus on order execution, Level 2 depth analysis, position management, "
                    "and risk per trade. Discuss slippage, order types (limit, market, stop), "
                    "and execution quality metrics.\n"
                )
            elif tab == "simulation":
                prompt += (
                    "Focus on learning insights, pattern recognition, strategy optimization, "
                    "and backtesting results. Discuss strategy performance across different market "
                    "regimes and suggest parameter tuning.\n"
                )

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

        max_retries = 4  # 3 attempts with primary model, 1 with fallback
        for attempt in range(max_retries):
            # On the last attempt, fall back to a smaller model if the error was retryable
            model_to_use = self._model
            if attempt == max_retries - 1:
                model_to_use = self._fallback_model
                log.info("chat.fallback_model", model=model_to_use)

            try:
                full_response = ""
                async with client.messages.stream(
                    model=model_to_use,
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
                    model=model_to_use,
                )
                return  # Success — exit retry loop

            except Exception as e:
                error_str = str(e)
                is_overloaded = "overloaded" in error_str.lower() or "529" in error_str
                is_rate_limited = "rate_limit" in error_str.lower() or "429" in error_str
                is_auth_error = "auth" in error_str.lower() or "401" in error_str or "invalid.*key" in error_str.lower()
                is_retryable = is_overloaded or is_rate_limited

                if is_retryable and attempt < max_retries - 1:
                    delay = 2 ** (attempt + 1)  # 2s, 4s, 8s
                    log.warning(
                        "chat.retrying",
                        attempt=attempt + 1,
                        delay=delay,
                        error=error_str,
                    )
                    # Silent retry — user sees the typing indicator, no need
                    # to inject retry text into the chat bubble
                    await asyncio.sleep(delay)
                    continue

                self._error_count += 1
                log.error(
                    "chat.stream_error",
                    error=error_str,
                    conversation_id=conversation_id,
                )

                # Provide a context-specific, helpful error message
                if is_overloaded:
                    user_error = "Claude is currently at capacity. Your message has been saved — please try again in a moment."
                elif is_rate_limited:
                    user_error = "Rate limit reached. Please wait a moment before sending another message."
                elif is_auth_error:
                    user_error = "API authentication failed. Please check your API key in Settings."
                else:
                    user_error = "An unexpected error occurred. Please try again."

                history.append(ChatMessage(role="assistant", content=user_error))
                yield user_error
                return  # Non-retryable or final attempt — stop

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
