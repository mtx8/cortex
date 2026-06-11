"""LocalProvider — private, offline-capable inference via an OpenAI-compatible
endpoint (Ollama 0.19+ with its MLX backend, or `mlx_lm.server`). This is the
default first hop: zero API cost, zero data egress, fastest on Apple M-series.
"""

from __future__ import annotations

import httpx
import structlog

from cortex.intelligence.providers.base import LLMProvider

log = structlog.get_logger()


class LocalProvider(LLMProvider):
    name = "local"
    is_cloud = False

    def __init__(self, base_url: str, model: str, timeout: float = 60.0):
        self._base_url = base_url.rstrip("/")
        self.model = model
        self._timeout = timeout

    async def available(self) -> bool:
        """True if the local server answers /models quickly. Never raises."""
        try:
            async with httpx.AsyncClient(timeout=2.0) as client:
                r = await client.get(f"{self._base_url}/models")
                return r.status_code == 200
        except Exception:
            return False

    async def complete(self, prompt: str, system: str | None = None,
                       max_tokens: int = 1024, temperature: float = 0.2) -> str:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": prompt})
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature,
            "stream": False,
        }
        async with httpx.AsyncClient(timeout=self._timeout) as client:
            r = await client.post(f"{self._base_url}/chat/completions", json=payload)
            r.raise_for_status()
            data = r.json()
        return data["choices"][0]["message"]["content"]
