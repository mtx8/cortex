"""LLM provider interface."""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class LLMResult:
    text: str
    provider: str
    model: str


class LLMProvider(ABC):
    """One LLM backend. `is_cloud` providers are skipped in offline_only mode."""

    name: str = "base"
    is_cloud: bool = False
    model: str = ""

    @abstractmethod
    async def available(self) -> bool:
        """Cheap reachability/credential check; must not raise."""
        ...

    @abstractmethod
    async def complete(
        self,
        prompt: str,
        system: str | None = None,
        max_tokens: int = 1024,
        temperature: float = 0.2,
    ) -> str:
        """Return the completion text. May raise on transport/credential errors;
        the router catches and falls through to the next provider."""
        ...

    def to_dict(self) -> dict:
        return {"name": self.name, "is_cloud": self.is_cloud, "model": self.model}
