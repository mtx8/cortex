"""Tests for CortexChat streaming Claude integration."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from collections import deque

from cortex.intelligence.chat import CortexChat, ChatMessage, _MAX_HISTORY
from cortex.orchestrator.bus import SignalBus


# ─── ChatMessage Tests ────────────────────────────────────────────────

def test_chat_message_defaults():
    msg = ChatMessage(role="user", content="Hello")
    assert msg.role == "user"
    assert msg.content == "Hello"
    assert msg.timestamp > 0


# ─── CortexChat Construction ─────────────────────────────────────────

def test_chat_creation():
    chat = CortexChat(api_key="test-key")
    assert chat._model == "claude-opus-4-6"
    assert chat.request_count == 0
    assert chat.error_count == 0


def test_chat_to_dict():
    chat = CortexChat(api_key="test-key", model="claude-opus-4-6")
    d = chat.to_dict()
    assert d["model"] == "claude-opus-4-6"
    assert d["has_api_key"] is True
    assert d["request_count"] == 0
    assert d["active_conversations"] == 0


def test_chat_no_api_key():
    chat = CortexChat(api_key="")
    assert chat.to_dict()["has_api_key"] is False


# ─── System Prompt ────────────────────────────────────────────────────

def test_build_system_prompt_empty_context():
    chat = CortexChat(api_key="test-key")
    prompt = chat.build_system_prompt()
    assert "CORTEX AI" in prompt
    assert "NAV: $0.00" in prompt
    assert "no open positions" in prompt
    assert "no recent signals" in prompt


def test_build_system_prompt_with_context():
    chat = CortexChat(api_key="test-key")
    chat.set_portfolio_context(
        nav=100000.0,
        daily_pnl=1500.0,
        positions=[
            {"symbol": "AAPL", "qty": 50, "avg_price": 180.0, "pnl": 250.0},
            {"symbol": "MSFT", "qty": 30, "avg_price": 370.0, "pnl": -100.0},
        ],
        top_signals=["alpha.entry_signal: NVDA", "alpha.volume_surge: TSLA"],
        risk_metrics={
            "drawdown_pct": 2.5,
            "win_rate": 0.65,
            "sharpe": 1.8,
            "open_positions": 5,
        },
    )
    prompt = chat.build_system_prompt()
    assert "$100,000.00" in prompt
    assert "$+1,500.00" in prompt
    assert "AAPL" in prompt
    assert "MSFT" in prompt
    assert "alpha.entry_signal: NVDA" in prompt
    assert "2.5%" in prompt
    assert "65.0%" in prompt


def test_build_system_prompt_negative_pnl():
    chat = CortexChat(api_key="test-key")
    chat.set_portfolio_context(nav=50000.0, daily_pnl=-500.0)
    prompt = chat.build_system_prompt()
    assert "$-500.00" in prompt


# ─── Context-Aware System Prompt ────────────────────────────────────

def test_build_system_prompt_with_ui_context_scanner():
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "scanner", "current_section": "options_flow"}
    prompt = chat.build_system_prompt(context=context)
    assert "scanner" in prompt
    assert "options_flow" in prompt
    assert "trading opportunities" in prompt


def test_build_system_prompt_with_ui_context_financials():
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "financials", "selected_symbol": "AAPL"}
    prompt = chat.build_system_prompt(context=context)
    assert "financials" in prompt
    assert "AAPL" in prompt
    assert "fundamental analysis" in prompt


def test_build_system_prompt_with_ui_context_war_room():
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "war_room"}
    prompt = chat.build_system_prompt(context=context)
    assert "war_room" in prompt
    assert "portfolio risk" in prompt


def test_build_system_prompt_with_ui_context_markets():
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "markets"}
    prompt = chat.build_system_prompt(context=context)
    assert "markets" in prompt
    assert "technical analysis" in prompt


def test_build_system_prompt_with_ui_context_watchlist():
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "watchlist"}
    prompt = chat.build_system_prompt(context=context)
    assert "watchlist" in prompt
    assert "position management" in prompt


def test_build_system_prompt_no_context():
    """build_system_prompt still works fine with no context (backward compat)."""
    chat = CortexChat(api_key="test-key")
    prompt = chat.build_system_prompt()
    assert "Current User Context" not in prompt
    assert "CORTEX AI" in prompt


def test_build_system_prompt_context_none_explicit():
    """Passing None explicitly should be same as no context."""
    chat = CortexChat(api_key="test-key")
    prompt = chat.build_system_prompt(context=None)
    assert "Current User Context" not in prompt


def test_build_system_prompt_context_unknown_tab():
    """Unknown tabs don't add tab-specific hints but still add context section."""
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "settings", "current_section": "unknown"}
    prompt = chat.build_system_prompt(context=context)
    assert "settings" in prompt
    # No tab-specific hints for 'settings'
    assert "trading opportunities" not in prompt
    assert "fundamental analysis" not in prompt


def test_build_system_prompt_context_with_selected_symbol():
    """Verify selected_symbol appears in context section."""
    chat = CortexChat(api_key="test-key")
    context = {"current_tab": "financials", "selected_symbol": "NVDA"}
    prompt = chat.build_system_prompt(context=context)
    assert "NVDA" in prompt
    assert "looking at the symbol" in prompt


# ─── Enriched Context (scanner, agents, market quotes) ──────────────

def test_build_system_prompt_with_scanner_opportunities():
    """Verify scanner opportunities are rendered into the system prompt."""
    chat = CortexChat(api_key="test-key")
    context = {
        "current_tab": "Scanner",
        "current_section": "Overview",
        "scanner_opportunities": [
            {"ticker": "NVDA", "score": 92.5, "type": "Breakout", "direction": "long",
             "risk_reward": 2.1, "thesis": "Breaking above $890 resistance"},
            {"ticker": "META", "score": 85.0, "type": "Momentum", "direction": "long",
             "risk_reward": 1.8, "thesis": "Strong RSI recovery"},
        ],
    }
    prompt = chat.build_system_prompt(context=context)
    assert "Active Scanner Results (2 opportunities)" in prompt
    assert "NVDA" in prompt
    assert "92.5" in prompt
    assert "Breakout" in prompt
    assert "META" in prompt
    assert "85.0" in prompt


def test_build_system_prompt_with_agents():
    """Verify agent health is rendered into the system prompt."""
    chat = CortexChat(api_key="test-key")
    context = {
        "current_tab": "Squadrons",
        "agents": [
            {"id": "signal_hunter", "squadron": "alpha", "status": "active",
             "signal_count": 42, "error_count": 0},
            {"id": "gap_scanner", "squadron": "alpha", "status": "active",
             "signal_count": 15, "error_count": 1},
            {"id": "risk_guardian", "squadron": "echo", "status": "active",
             "signal_count": 100, "error_count": 0},
        ],
    }
    prompt = chat.build_system_prompt(context=context)
    assert "Squadron Health (3 agents)" in prompt
    assert "ALPHA" in prompt
    assert "ECHO" in prompt
    assert "signal_hunter" in prompt
    assert "risk_guardian" in prompt


def test_build_system_prompt_with_market_quotes():
    """Verify market quotes are rendered into the system prompt."""
    chat = CortexChat(api_key="test-key")
    context = {
        "current_tab": "Markets",
        "market_quotes": {
            "AAPL": {"price": 185.50, "change": 2.50, "change_pct": 1.37},
            "NVDA": {"price": 892.00, "change": -5.00, "change_pct": -0.56},
        },
    }
    prompt = chat.build_system_prompt(context=context)
    assert "Live Market Quotes" in prompt
    assert "$185.50" in prompt
    assert "NVDA" in prompt


def test_build_system_prompt_with_kill_switch():
    """Verify kill switch status is rendered."""
    chat = CortexChat(api_key="test-key")
    context = {
        "current_tab": "War Room",
        "kill_switch": {"active": True, "reason": "daily drawdown exceeded 7%"},
    }
    prompt = chat.build_system_prompt(context=context)
    assert "KILL SWITCH ACTIVE" in prompt
    assert "daily drawdown exceeded 7%" in prompt


def test_build_system_prompt_enriched_portfolio():
    """Verify enriched portfolio data (total_pnl, win_rate, sharpe, etc.) renders."""
    chat = CortexChat(api_key="test-key")
    context = {
        "current_tab": "War Room",
        "portfolio": {
            "nav": 125000.0,
            "daily_pnl": 3500.0,
            "total_pnl": 15000.0,
            "win_rate": 0.67,
            "sharpe_ratio": 1.85,
            "buying_power": 48000.0,
            "open_positions": 5,
        },
    }
    prompt = chat.build_system_prompt(context=context)
    assert "$125,000.00" in prompt
    assert "$+3,500.00" in prompt
    assert "Total P&L: $+15,000.00" in prompt
    assert "Win Rate: 67.0%" in prompt
    assert "Sharpe: 1.85" in prompt
    assert "Buying Power: $48,000.00" in prompt
    assert "Open Positions: 5" in prompt


def test_build_system_prompt_tab_normalization():
    """Verify tab names with spaces (from Swift) are normalized correctly."""
    chat = CortexChat(api_key="test-key")
    # Swift sends "War Room" not "war_room"
    context = {"current_tab": "War Room"}
    prompt = chat.build_system_prompt(context=context)
    assert "War Room" in prompt
    assert "portfolio risk" in prompt


# ─── Conversation History ────────────────────────────────────────────

def test_conversation_history_management():
    chat = CortexChat(api_key="test-key")
    assert chat.get_conversation_length("test") == 0

    # Manually add messages to history
    history = chat._get_history("test")
    history.append(ChatMessage(role="user", content="Hello"))
    history.append(ChatMessage(role="assistant", content="Hi there"))

    assert chat.get_conversation_length("test") == 2


def test_conversation_max_history():
    chat = CortexChat(api_key="test-key")
    history = chat._get_history("test")

    # Fill beyond max
    for i in range(_MAX_HISTORY + 5):
        history.append(ChatMessage(role="user", content=f"msg {i}"))

    assert len(history) == _MAX_HISTORY


def test_clear_conversation():
    chat = CortexChat(api_key="test-key")
    history = chat._get_history("test")
    history.append(ChatMessage(role="user", content="Hello"))
    assert chat.get_conversation_length("test") == 1

    chat.clear_conversation("test")
    assert chat.get_conversation_length("test") == 0


def test_clear_nonexistent_conversation():
    chat = CortexChat(api_key="test-key")
    # Should not raise
    chat.clear_conversation("nonexistent")


def test_history_to_messages():
    chat = CortexChat(api_key="test-key")
    history = chat._get_history("test")
    history.append(ChatMessage(role="user", content="Hello"))
    history.append(ChatMessage(role="assistant", content="Hi!"))
    history.append(ChatMessage(role="user", content="How are you?"))

    messages = chat._history_to_messages("test")
    assert len(messages) == 3
    assert messages[0] == {"role": "user", "content": "Hello"}
    assert messages[1] == {"role": "assistant", "content": "Hi!"}
    assert messages[2] == {"role": "user", "content": "How are you?"}


# ─── Streaming (mocked SDK) ──────────────────────────────────────────

@pytest.mark.asyncio
async def test_stream_response_no_sdk():
    """When anthropic SDK is unavailable, yields fallback message."""
    chat = CortexChat(api_key="test-key")

    # Force client to be None (simulating missing SDK)
    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=None):
        chunks = []
        async for chunk in chat.stream_response("Hello"):
            chunks.append(chunk)

    assert len(chunks) == 1
    assert "unavailable" in chunks[0].lower()
    assert chat.get_conversation_length("default") == 2  # user + assistant fallback


@pytest.mark.asyncio
async def test_stream_response_with_mock_client():
    """Verify streaming works with a mocked Anthropic client."""
    chat = CortexChat(api_key="test-key")

    # Create mock streaming context
    mock_text_chunks = ["Hello", " there", "! How", " can I help?"]

    class MockTextStream:
        def __init__(self):
            self.chunks = list(mock_text_chunks)
            self.idx = 0

        def __aiter__(self):
            return self

        async def __anext__(self):
            if self.idx >= len(self.chunks):
                raise StopAsyncIteration
            chunk = self.chunks[self.idx]
            self.idx += 1
            return chunk

    class MockStreamContext:
        def __init__(self):
            self.text_stream = MockTextStream()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    mock_client = MagicMock()
    mock_client.messages.stream.return_value = MockStreamContext()

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=mock_client):
        chunks = []
        async for chunk in chat.stream_response("What is my P&L?"):
            chunks.append(chunk)

    assert chunks == mock_text_chunks
    assert chat.request_count == 1
    assert chat.get_conversation_length("default") == 2  # user + assistant

    # Verify the full response was stored in history
    history = list(chat._get_history("default"))
    assert history[0].role == "user"
    assert history[0].content == "What is my P&L?"
    assert history[1].role == "assistant"
    assert history[1].content == "Hello there! How can I help?"


@pytest.mark.asyncio
async def test_stream_response_error_handling():
    """Verify errors are caught and yielded as error messages."""
    chat = CortexChat(api_key="test-key")

    mock_client = MagicMock()
    mock_client.messages.stream.side_effect = Exception("API rate limit exceeded")

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=mock_client):
        chunks = []
        async for chunk in chat.stream_response("Hello"):
            chunks.append(chunk)

    assert len(chunks) == 1
    assert "error" in chunks[0].lower()
    assert "try again" in chunks[0].lower()
    assert chat.error_count == 1


@pytest.mark.asyncio
async def test_stream_response_separate_conversations():
    """Verify separate conversation IDs maintain separate histories."""
    chat = CortexChat(api_key="test-key")

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=None):
        async for _ in chat.stream_response("Hello from A", conversation_id="conv_a"):
            pass
        async for _ in chat.stream_response("Hello from B", conversation_id="conv_b"):
            pass

    assert chat.get_conversation_length("conv_a") == 2
    assert chat.get_conversation_length("conv_b") == 2

    history_a = list(chat._get_history("conv_a"))
    history_b = list(chat._get_history("conv_b"))
    assert history_a[0].content == "Hello from A"
    assert history_b[0].content == "Hello from B"


@pytest.mark.asyncio
async def test_stream_passes_system_prompt():
    """Verify the system prompt with portfolio context is passed to Claude."""
    chat = CortexChat(api_key="test-key")
    chat.set_portfolio_context(nav=75000.0, daily_pnl=300.0)

    class MockTextStream:
        def __aiter__(self):
            return self

        async def __anext__(self):
            raise StopAsyncIteration

    class MockStreamContext:
        def __init__(self):
            self.text_stream = MockTextStream()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    mock_client = MagicMock()
    mock_client.messages.stream.return_value = MockStreamContext()

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=mock_client):
        async for _ in chat.stream_response("Test"):
            pass

    # Verify the stream was called with correct parameters
    call_kwargs = mock_client.messages.stream.call_args.kwargs
    assert call_kwargs["model"] == "claude-opus-4-6"
    assert "$75,000.00" in call_kwargs["system"]
    assert "$+300.00" in call_kwargs["system"]
    assert call_kwargs["messages"][0]["content"] == "Test"


@pytest.mark.asyncio
async def test_stream_passes_context_to_system_prompt():
    """Verify UI context is included in the system prompt sent to Claude."""
    chat = CortexChat(api_key="test-key")

    class MockTextStream:
        def __aiter__(self):
            return self

        async def __anext__(self):
            raise StopAsyncIteration

    class MockStreamContext:
        def __init__(self):
            self.text_stream = MockTextStream()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            pass

    mock_client = MagicMock()
    mock_client.messages.stream.return_value = MockStreamContext()

    context = {"current_tab": "financials", "selected_symbol": "TSLA"}

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=mock_client):
        async for _ in chat.stream_response("Analyze this stock", context=context):
            pass

    call_kwargs = mock_client.messages.stream.call_args.kwargs
    assert "financials" in call_kwargs["system"]
    assert "TSLA" in call_kwargs["system"]
    assert "fundamental analysis" in call_kwargs["system"]


@pytest.mark.asyncio
async def test_stream_response_no_context_backward_compat():
    """Verify stream_response works without context parameter (backward compatibility)."""
    chat = CortexChat(api_key="test-key")

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=None):
        chunks = []
        async for chunk in chat.stream_response("Hello"):
            chunks.append(chunk)

    assert len(chunks) == 1
    assert "unavailable" in chunks[0].lower()
