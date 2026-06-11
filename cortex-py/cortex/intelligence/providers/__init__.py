"""Pluggable LLM providers + a local-first router.

Order: local (Ollama/MLX, OpenAI-compatible) -> Claude -> Gemini, with an
`offline_only` hard-lock that disables all cloud egress for privacy-locked
sessions. Claude remains the strategic-cycle brain (CLAUDE.md rule #5/#7); no LLM
ever runs in the execution hot path. Build the abstraction here; call sites
(claude_engine, chat, news sentiment) migrate onto it incrementally.
"""

from cortex.intelligence.providers.base import LLMProvider, LLMResult
from cortex.intelligence.providers.local import LocalProvider
from cortex.intelligence.providers.claude import ClaudeProvider
from cortex.intelligence.providers.gemini import GeminiProvider
from cortex.intelligence.providers.router import LLMRouter, build_router

__all__ = [
    "LLMProvider", "LLMResult", "LocalProvider", "ClaudeProvider",
    "GeminiProvider", "LLMRouter", "build_router",
]
