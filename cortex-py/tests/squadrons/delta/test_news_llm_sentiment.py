"""NewsCatalyst LLM-sentiment path tests (router-backed, keyword fallback)."""

from dataclasses import dataclass

from cortex.orchestrator.bus import SignalBus
from cortex.squadrons.delta.news_catalyst import NewsCatalyst


@dataclass
class _Result:
    text: str
    provider: str = "local"
    model: str = "m"


class _Router:
    def __init__(self, text=None, raise_err=False):
        self._text = text
        self._raise = raise_err

    async def complete(self, prompt, system=None, max_tokens=1024, temperature=0.2):
        if self._raise:
            raise RuntimeError("down")
        if self._text is None:
            return None
        return _Result(self._text)


async def test_llm_sentiment_parses_number():
    agent = NewsCatalyst(SignalBus(), llm_router=_Router(text="0.8"))
    s = await agent.score_sentiment_llm("MegaCorp beats earnings")
    assert abs(s.score - 0.8) < 1e-9 and s.label == "positive"

    s2 = await NewsCatalyst(SignalBus(), llm_router=_Router(text="-0.6")).score_sentiment_llm("x")
    assert s2.label == "negative"


async def test_llm_sentiment_clamps_and_parses_embedded():
    agent = NewsCatalyst(SignalBus(), llm_router=_Router(text="score: 0.3 (bullish)"))
    s = await agent.score_sentiment_llm("x")
    assert abs(s.score - 0.3) < 1e-9
    # out-of-range clamps to [-1, 1]
    agent2 = NewsCatalyst(SignalBus(), llm_router=_Router(text="2.5"))
    s2 = await agent2.score_sentiment_llm("x")
    assert s2.score == 1.0


async def test_llm_none_falls_back_to_keyword():
    agent = NewsCatalyst(SignalBus(), llm_router=_Router(text=None))
    s = await agent.score_sentiment_llm("stock surges to record beat")  # keyword-positive
    assert s.label == "positive"


async def test_llm_error_falls_back_to_keyword():
    agent = NewsCatalyst(SignalBus(), llm_router=_Router(raise_err=True))
    s = await agent.score_sentiment_llm("massive loss decline plunge")  # keyword-negative
    assert s.label == "negative"


async def test_no_router_uses_keyword():
    agent = NewsCatalyst(SignalBus())  # no router
    s = await agent.score_sentiment_llm("beats record surge")
    assert s.label == "positive"


async def test_parse_score_garbage_returns_none():
    assert NewsCatalyst._parse_score("no number here") is None
    assert abs(NewsCatalyst._parse_score("0.42") - 0.42) < 1e-9
