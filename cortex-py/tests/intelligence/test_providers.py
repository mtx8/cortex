"""LLMRouter routing + fallback + offline_only tests (mock providers)."""

import pytest

from cortex.intelligence.providers.base import LLMProvider
from cortex.intelligence.providers.router import LLMRouter, build_router


class FakeProvider(LLMProvider):
    def __init__(self, name, is_cloud=False, avail=True, text="ok", raise_on_complete=False):
        self.name = name
        self.is_cloud = is_cloud
        self.model = f"{name}-model"
        self._avail = avail
        self._text = text
        self._raise = raise_on_complete
        self.complete_calls = 0

    async def available(self) -> bool:
        return self._avail

    async def complete(self, prompt, system=None, max_tokens=1024, temperature=0.2) -> str:
        self.complete_calls += 1
        if self._raise:
            raise RuntimeError("boom")
        return self._text


async def test_router_picks_first_available():
    local = FakeProvider("local", is_cloud=False, text="local-answer")
    claude = FakeProvider("claude", is_cloud=True, text="claude-answer")
    r = LLMRouter([local, claude])
    res = await r.complete("hi")
    assert res is not None
    assert res.provider == "local" and res.text == "local-answer"
    assert claude.complete_calls == 0  # never reached


async def test_router_falls_through_unavailable():
    local = FakeProvider("local", avail=False)
    claude = FakeProvider("claude", is_cloud=True, text="claude-answer")
    r = LLMRouter([local, claude])
    res = await r.complete("hi")
    assert res.provider == "claude"
    assert local.complete_calls == 0


async def test_router_falls_through_on_error():
    local = FakeProvider("local", raise_on_complete=True)
    claude = FakeProvider("claude", is_cloud=True, text="claude-answer")
    r = LLMRouter([local, claude])
    res = await r.complete("hi")
    assert res.provider == "claude"
    assert local.complete_calls == 1  # tried, then fell through


async def test_offline_only_skips_cloud():
    local = FakeProvider("local", avail=False)        # local down
    claude = FakeProvider("claude", is_cloud=True)    # cloud — must be skipped
    r = LLMRouter([local, claude], offline_only=True)
    res = await r.complete("hi")
    assert res is None  # no cloud allowed, local unavailable
    assert claude.complete_calls == 0


async def test_no_provider_returns_none():
    r = LLMRouter([FakeProvider("a", avail=False), FakeProvider("b", avail=False)])
    assert await r.complete("hi") is None


async def test_build_router_from_config():
    from cortex.config import CortexConfig
    cfg = CortexConfig(llm_provider_order="local,claude,gemini", llm_offline_only=True)
    r = build_router(cfg)
    names = [p["name"] for p in r.to_dict()["providers"]]
    assert names == ["local", "claude", "gemini"]
    assert r.offline_only is True
