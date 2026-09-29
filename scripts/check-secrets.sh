#!/usr/bin/env bash
# SEC-04 local pre-commit equivalent of .github/workflows/ci.yml secret-scan job.
#
# Usage: bash scripts/check-secrets.sh
#
# Exits 0 if no literal API key prefixes are found in source files.
# Exits 1 if any match is found — prints the offending lines first.
#
# NOTE: *.toml files are excluded from the scan. The TOML config fixture
# (AgentsUsageBarTests/ConfigTests/Fixtures/valid.toml) uses a clearly-fake key
# value to test parsing; it does not contain a real credential.
#
# NOTE: ci.yml is excluded via --exclude='ci.yml' to avoid self-reference
# (the PATTERNS variable in ci.yml contains the forbidden prefixes as its definition).
set -euo pipefail

# Keep identical to PATTERNS in .github/workflows/ci.yml (length-gated so short
# fixtures such as `sk-or-v1-test` pass; see the comment block there).
PATTERNS='sk-or-v1-[A-Za-z0-9]{40,}|AIzaSy[A-Za-z0-9_-]{30,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-admin-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|BEGIN OPENSSH PRIVATE KEY|Authorization: Bearer [A-Za-z0-9._~+/=-]{20,}|OLLAMA_API_KEY["'\'' :=]+[A-Za-z0-9._+/-]{24,}'

FOUND=0

if grep -RIEn --include='*.swift' --include='*.plist' --include='*.yml' --include='*.json' --include='*.md' \
           --exclude='ci.yml' \
           "$PATTERNS" \
           AgentsUsageBar/ AgentsUsageBarTests/ .github/ .scratch/ docs/ README.md 2>/dev/null; then
  FOUND=1
fi

if [ "$FOUND" -eq 1 ]; then
  echo "Blocked: literal API key prefix found in source. See SEC-04."
  exit 1
fi

echo "OK: No literal API key prefixes."
