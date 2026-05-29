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

PATTERNS='sk-proj-|sk-admin-|sk-or-|AIzaSy|sk-[A-Za-z0-9]{20,}'

FOUND=0

if grep -RIEn --include='*.swift' --include='*.plist' --include='*.yml' \
           --exclude='ci.yml' \
           "$PATTERNS" \
           AgentsUsageBar/ AgentsUsageBarTests/ .github/ 2>/dev/null; then
  FOUND=1
fi

if [ "$FOUND" -eq 1 ]; then
  echo "Blocked: literal API key prefix found in source. See SEC-04."
  exit 1
fi

echo "OK: No literal API key prefixes."
