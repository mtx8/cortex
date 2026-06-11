"""GeminiProvider — Google Gemini cloud (Flash tier), an optional cheap
structured-output fallback. Skipped in offline_only mode. Uses the REST API via
httpx so it needs no extra SDK dependency.
"""

from __future__ import annotations

import httpx
import structlog

from cortex.intelligence.providers.base import LLMProvider

log = structlog.get_logger()

_BASE = "https://generativelanguage.googleapis.com/v1beta/models"


class GeminiProvider(LLMProvider):
    name = "gemini"
    is_cloud = True

    def __init__(self, api_key: str, model: str = "gemini-2.5-flash", timeout: float = 60.0):
        self._api_key = api_key
        self.model = model
        self._timeout = timeout

    async def available(self) -> bool:
        return bool(self._api_key)

    async def complete(self, prompt: str, system: str | None = None,
                       max_tokens: int = 1024, temperature: float = 0.2) -> str:
        if not self._api_key:
            raise RuntimeError("gemini api key missing")
        url = f"{_BASE}/{self.model}:generateContent?key={self._api_key}"
        body: dict = {
            "contents": [{"parts": [{"text": prompt}]}],
            "generationConfig": {"maxOutputTokens": max_tokens, "temperature": temperature},
        }
        if system:
            body["systemInstruction"] = {"parts": [{"text": system}]}
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            r = await client.post(url, json=body)
            r.raise_for_status()
            data = r.json()
        return data["candidates"][0]["content"]["parts"][0]["text"]
