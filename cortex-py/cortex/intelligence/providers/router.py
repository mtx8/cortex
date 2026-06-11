"""LLMRouter — local-first routing with graceful fallback.

Tries providers in configured order, skipping cloud providers when offline_only is
set and skipping any provider whose `available()` is False. Returns the first
success; records which provider answered and how many fallbacks occurred. Never
puts an LLM in the execution hot path — this serves the strategic cycle, research,
and sentiment paths only.
"""

from __future__ import annotations

import structlog

from cortex.intelligence.providers.base import LLMProvider, LLMResult

log = structlog.get_logger()


class LLMRouter:
    def __init__(self, providers: list[LLMProvider], offline_only: bool = False):
        self._providers = providers
        self._offline_only = offline_only
        self._last_provider: str | None = None
        self._fallback_count = 0
        self._call_count = 0

    @property
    def offline_only(self) -> bool:
        return self._offline_only

    def set_offline_only(self, value: bool) -> None:
        self._offline_only = value

    async def complete(self, prompt: str, system: str | None = None,
                       max_tokens: int = 1024, temperature: float = 0.2) -> LLMResult | None:
        self._call_count += 1
        for p in self._providers:
            if self._offline_only and p.is_cloud:
                continue
            try:
                if not await p.available():
                    continue
                text = await p.complete(prompt, system=system,
                                        max_tokens=max_tokens, temperature=temperature)
            except Exception as e:
                log.warning("llm_router.provider_error", provider=p.name, error=str(e))
                continue
            if self._last_provider is not None and self._last_provider != p.name:
                self._fallback_count += 1
            self._last_provider = p.name
            return LLMResult(text=text, provider=p.name, model=p.model)
        log.warning("llm_router.no_provider", offline_only=self._offline_only)
        return None

    def to_dict(self) -> dict:
        return {
            "providers": [p.to_dict() for p in self._providers],
            "offline_only": self._offline_only,
            "last_provider": self._last_provider,
            "fallback_count": self._fallback_count,
            "call_count": self._call_count,
        }


_PROVIDER_FACTORIES = {
    "local": lambda c: __import__(
        "cortex.intelligence.providers.local", fromlist=["LocalProvider"]
    ).LocalProvider(base_url=c.local_llm_base_url, model=c.local_llm_model),
    "claude": lambda c: __import__(
        "cortex.intelligence.providers.claude", fromlist=["ClaudeProvider"]
    ).ClaudeProvider(api_key=c.anthropic_api_key, model=c.claude_model),
    "gemini": lambda c: __import__(
        "cortex.intelligence.providers.gemini", fromlist=["GeminiProvider"]
    ).GeminiProvider(api_key=c.gemini_api_key, model=c.gemini_model),
}


def build_router(config) -> LLMRouter:
    """Build an LLMRouter from CortexConfig (provider order + offline_only)."""
    order = [p.strip() for p in config.llm_provider_order.split(",") if p.strip()]
    providers: list[LLMProvider] = []
    for name in order:
        factory = _PROVIDER_FACTORIES.get(name)
        if factory is None:
            log.warning("llm_router.unknown_provider", provider=name)
            continue
        providers.append(factory(config))
    return LLMRouter(providers, offline_only=config.llm_offline_only)
