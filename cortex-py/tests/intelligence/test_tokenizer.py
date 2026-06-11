"""Local tokenizer (tiktoken / Karpathy) tests — work with or without tiktoken."""

from cortex.intelligence import tokenizer as tok


def test_count_tokens_basic():
    assert tok.count_tokens("") == 0
    assert tok.count_tokens("hello world") >= 1
    # A longer string has more tokens than a short one.
    assert tok.count_tokens("the quick brown fox jumps over the lazy dog") > \
        tok.count_tokens("hi")


def test_fits_budget():
    assert tok.fits_budget("short", 100) is True
    assert tok.fits_budget("word " * 500, 10) is False


def test_truncate_to_budget():
    long = "token " * 1000
    out = tok.truncate_to_budget(long, 20)
    assert tok.count_tokens(out) <= 20
    # No-op when already under budget.
    assert tok.truncate_to_budget("tiny", 100) == "tiny"
    assert tok.truncate_to_budget("anything", 0) == ""
