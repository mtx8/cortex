#!/usr/bin/env bash
# CORTEX preflight security gate — run before any release/build.
# Mirrors omniscient-macos/scripts/preflight-security.sh. FAILS on real security
# violations (hardcoded secrets, iCloud paths, missing lockfile, empty egress
# allowlist, CORS proxies); WARNS when optional auditors aren't installed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
FAIL=0
warn() { printf "  \033[33mWARN\033[0m  %s\n" "$1"; }
ok()   { printf "  \033[32mOK\033[0m    %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAIL=1; }

echo "== CORTEX preflight security gate =="

# 1) Rust lockfile committed (reproducible supply chain)
if [ -f cortex-rs/Cargo.lock ]; then ok "cortex-rs/Cargo.lock present"; else bad "cortex-rs/Cargo.lock missing"; fi

# 2) No hardcoded secrets in source (exclude tests, .env, examples)
SECRET_HITS=$(grep -rEn "(sk-ant-[A-Za-z0-9]|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----)" \
  cortex-py/cortex cortex-rs/src cortex-app/Sources 2>/dev/null | grep -vE "\.env|test_|/tests/" || true)
if [ -z "$SECRET_HITS" ]; then ok "no hardcoded secrets in source"; else bad "hardcoded secret(s):"; echo "$SECRET_HITS"; fi

# 3) No iCloud path references (HARD RULE #1)
ICLOUD_HITS=$(grep -rEn "Mobile Documents|com~apple~CloudDocs" \
  cortex-py/cortex cortex-rs/src cortex-app/Sources scripts 2>/dev/null \
  | grep -v "preflight-security.sh" || true)
if [ -z "$ICLOUD_HITS" ]; then ok "no iCloud path references"; else bad "iCloud path reference(s):"; echo "$ICLOUD_HITS"; fi

# 4) No CORS-proxy egress (must go through the Rust allowlist chokepoint)
CORS_HITS=$(grep -rEn "corsproxy\.io|allorigins\.win|cors-anywhere" \
  cortex-py/cortex cortex-app/Sources 2>/dev/null || true)
if [ -z "$CORS_HITS" ]; then ok "no CORS-proxy egress"; else bad "CORS proxy found:"; echo "$CORS_HITS"; fi

# 5) Egress allowlist present + non-empty
VENV_PY="cortex-py/.venv/bin/python"
if [ -x "$VENV_PY" ]; then
  N=$("$VENV_PY" -c "import cortex_scanner as c; print(len(c.allowed_hosts()))" 2>/dev/null || echo 0)
  if [ "${N:-0}" -gt 0 ]; then ok "egress allowlist non-empty ($N hosts)"; else bad "egress allowlist empty / geo core not built"; fi
else
  warn "cortex-py/.venv not found — skipping egress allowlist check"
fi

# 6) Optional auditors (warn if absent — do not block local dev)
if command -v cargo-deny >/dev/null 2>&1 || cargo deny --version >/dev/null 2>&1; then
  (cd cortex-rs && cargo deny check 2>/dev/null) && ok "cargo deny clean" || bad "cargo deny found issues"
else warn "cargo-deny not installed (cargo install cargo-deny)"; fi

if cargo audit --version >/dev/null 2>&1; then
  (cd cortex-rs && cargo audit 2>/dev/null) && ok "cargo audit clean" || bad "cargo audit found advisories"
else warn "cargo-audit not installed (cargo install cargo-audit)"; fi

if command -v pip-audit >/dev/null 2>&1; then
  (cd cortex-py && pip-audit 2>/dev/null) && ok "pip-audit clean" || warn "pip-audit reported advisories"
else warn "pip-audit not installed (uv tool install pip-audit)"; fi

echo "== preflight $( [ $FAIL -eq 0 ] && echo PASS || echo FAIL ) =="
exit $FAIL
