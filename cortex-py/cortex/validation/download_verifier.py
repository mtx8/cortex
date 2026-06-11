"""DownloadVerifier — checksum/manifest verification for anything CORTEX pulls
(models, weights, data files, vendored deps). Nothing is trusted on filename
alone: a SHA-256 must match a pinned manifest before a file is used. Pure stdlib
(hashlib) — no third-party trust to bootstrap the trust check.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

_CHUNK = 1024 * 1024


@dataclass
class VerificationResult:
    ok: bool
    path: str
    expected: str
    actual: str
    reason: str = ""


class DownloadVerifier:
    """Verify files against pinned SHA-256 hashes."""

    @staticmethod
    def sha256_file(path: str | Path) -> str:
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(_CHUNK), b""):
                h.update(chunk)
        return h.hexdigest()

    @staticmethod
    def sha256_bytes(data: bytes) -> str:
        return hashlib.sha256(data).hexdigest()

    def verify_file(self, path: str | Path, expected_sha256: str) -> VerificationResult:
        p = Path(path)
        expected = expected_sha256.strip().lower()
        if not p.is_file():
            return VerificationResult(False, str(p), expected, "", "file not found")
        actual = self.sha256_file(p)
        ok = (actual == expected)
        return VerificationResult(ok, str(p), expected, actual,
                                  "" if ok else "sha256 mismatch")

    def verify_bytes(self, data: bytes, expected_sha256: str) -> bool:
        return self.sha256_bytes(data) == expected_sha256.strip().lower()

    def verify_manifest(self, manifest: dict[str, str]) -> list[VerificationResult]:
        """Verify every (path -> sha256) entry. Returns one result per entry."""
        return [self.verify_file(path, sha) for path, sha in manifest.items()]

    def all_ok(self, results: list[VerificationResult]) -> bool:
        return all(r.ok for r in results)

    def unpinned_files(self, directory: str | Path, manifest: dict[str, str],
                       suffixes: tuple[str, ...] = (".gguf", ".safetensors", ".bin",
                                                    ".mlpackage", ".npz", ".pt")) -> list[str]:
        """Model/weight files present on disk but absent from the pinned manifest —
        these must never be loaded (provenance unknown)."""
        d = Path(directory)
        if not d.is_dir():
            return []
        pinned = {str(Path(p).resolve()) for p in manifest}
        out = []
        for f in d.rglob("*"):
            if f.is_file() and f.suffix.lower() in suffixes and str(f.resolve()) not in pinned:
                out.append(str(f))
        return out

    @staticmethod
    def egress_allowlist() -> list[str]:
        """The Rust egress allowlist — the ONLY OSINT/geo network surface."""
        try:
            import cortex_scanner  # type: ignore
            return list(cortex_scanner.allowed_hosts())
        except Exception:
            return []
