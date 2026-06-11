"""DownloadVerifier tests — checksum / manifest / unpinned-file detection."""

import hashlib

from cortex.validation.download_verifier import DownloadVerifier


def test_sha256_and_verify_file(tmp_path):
    f = tmp_path / "model.bin"
    f.write_bytes(b"weights-v1")
    digest = hashlib.sha256(b"weights-v1").hexdigest()

    v = DownloadVerifier()
    assert v.sha256_file(f) == digest

    good = v.verify_file(f, digest)
    assert good.ok and good.actual == digest and good.reason == ""

    bad = v.verify_file(f, "0" * 64)
    assert not bad.ok and bad.reason == "sha256 mismatch"


def test_verify_missing_file(tmp_path):
    v = DownloadVerifier()
    res = v.verify_file(tmp_path / "nope.bin", "abc")
    assert not res.ok and res.reason == "file not found"


def test_verify_bytes_case_insensitive():
    v = DownloadVerifier()
    d = hashlib.sha256(b"x").hexdigest()
    assert v.verify_bytes(b"x", d.upper()) is True
    assert v.verify_bytes(b"x", "deadbeef") is False


def test_verify_manifest(tmp_path):
    a = tmp_path / "a.safetensors"; a.write_bytes(b"A")
    b = tmp_path / "b.gguf"; b.write_bytes(b"B")
    manifest = {
        str(a): hashlib.sha256(b"A").hexdigest(),
        str(b): hashlib.sha256(b"WRONG").hexdigest(),
    }
    v = DownloadVerifier()
    results = v.verify_manifest(manifest)
    assert len(results) == 2
    assert not v.all_ok(results)
    assert sum(1 for r in results if r.ok) == 1


def test_unpinned_files_detected(tmp_path):
    pinned = tmp_path / "good.gguf"; pinned.write_bytes(b"G")
    rogue = tmp_path / "rogue.safetensors"; rogue.write_bytes(b"R")
    manifest = {str(pinned): hashlib.sha256(b"G").hexdigest()}
    v = DownloadVerifier()
    unpinned = v.unpinned_files(tmp_path, manifest)
    assert str(rogue) in unpinned and str(pinned) not in unpinned


def test_egress_allowlist_passthrough():
    # cortex_scanner is installed in the test env; allowlist must be non-empty.
    hosts = DownloadVerifier.egress_allowlist()
    assert isinstance(hosts, list) and len(hosts) > 0
    assert "earthquake.usgs.gov" in hosts
