"""Local tokenization & token budgeting via tiktoken (Andrej Karpathy / OpenAI,
MIT, Rust-backed). Runs fully offline on Apple M-series. Falls back to a
whitespace heuristic if tiktoken is not installed, so token budgeting — used to
keep prompts inside the on-device LLM's small context — always works.
"""

from __future__ import annotations

import structlog

log = structlog.get_logger()

try:
    import tiktoken  # MIT, Rust-backed
    _ENC = tiktoken.get_encoding("cl100k_base")
except Exception:  # pragma: no cover - exercised in tiktoken-less environments
    _ENC = None
    log.info("tokenizer.tiktoken_missing", note="using whitespace heuristic")


def count_tokens(text: str) -> int:
    """Token count for `text`. Exact with tiktoken, ~1.33×words otherwise."""
    if not text:
        return 0
    if _ENC is not None:
        return len(_ENC.encode(text))
    return max(1, int(len(text.split()) * 1.33))


def fits_budget(text: str, budget: int) -> bool:
    return count_tokens(text) <= budget


def truncate_to_budget(text: str, budget: int) -> str:
    """Truncate `text` so it fits within `budget` tokens (keeps the head)."""
    if budget <= 0:
        return ""
    if _ENC is not None:
        toks = _ENC.encode(text)
        if len(toks) <= budget:
            return text
        return _ENC.decode(toks[:budget])
    # Heuristic path: trim words until under budget.
    words = text.split()
    if count_tokens(text) <= budget:
        return text
    keep = max(1, int(budget / 1.33))
    return " ".join(words[:keep])


def using_tiktoken() -> bool:
    return _ENC is not None
