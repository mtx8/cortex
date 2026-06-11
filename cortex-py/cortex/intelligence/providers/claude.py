"""ClaudeProvider — Anthropic cloud, the strategic-cycle brain. Skipped in
offline_only mode. Wraps the AsyncAnthropic SDK already used by claude_engine.
"""

from __future__ import annotations

import structlog

from cortex.intelligence.providers.base import LLMProvider

log = structlog.get_logger()


class ClaudeProvider(LLMProvider):
    name = "claude"
    is_cloud = True

    def __init__(self, api_key: str, model: str = "claude-opus-4-6"):
        self._api_key = api_key
        self.model = model
        self._client = None

    def _get_client(self):
        if self._client is None and self._api_key:
            try:
                import anthropic
                self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
            except ImportError:
                log.warning("claude_provider.sdk_missing")
                self._client = None
        return self._client

    async def available(self) -> bool:
        return bool(self._api_key) and self._get_client() is not None

    async def complete(self, prompt: str, system: str | None = None,
                       max_tokens: int = 1024, temperature: float = 0.2) -> str:
        client = self._get_client()
        if client is None:
            raise RuntimeError("anthropic client unavailable")
        kwargs = {
            "model": self.model,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "messages": [{"role": "user", "content": prompt}],
        }
        if system:
            kwargs["system"] = system
        resp = await client.messages.create(**kwargs)
        return resp.content[0].text
