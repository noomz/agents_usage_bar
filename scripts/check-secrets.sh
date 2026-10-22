#!/usr/bin/env bash
# SEC-04 secret scan. The CI secret-scan job in .github/workflows/ci.yml runs this script,
# so the patterns live here only.
#
# Usage: bash scripts/check-secrets.sh
#
# Exits 0 if no literal API key and no real email address is found in source files.
# Exits 1 if any match is found — prints the offending lines first.
#
# NOTE: *.toml files are excluded from the scan. The TOML config fixture
# (AgentsUsageBarTests/ConfigTests/Fixtures/valid.toml) uses a clearly-fake key
# value to test parsing; it does not contain a real credential.
set -euo pipefail

cd "$(dirname "$0")/.."

# Patterns are LENGTH-GATED on each provider's real key suffix so the scanner catches
# genuine leaked keys but NOT the bare prefixes and short fixtures that legitimately
# appear in tests and doc comments (e.g. `sk-or-v1-test`, or the prefix list in
# OnboardingCopy). A bare `sk-or-` or `AIzaSy` substring is not a secret; only a prefix
# followed by a full-length random suffix is.
#   sk-or-v1- + 64 hex (OpenRouter)  -> require >=40 of the suffix
#   AIzaSy    + 33 chars (Google)     -> require >=30
#   sk-proj-/sk-admin- + long (OpenAI)-> require >=20
#   generic sk-<48 alnum> (OpenAI)    -> require >=32 contiguous alnum
#   OpenSSH private key header, literal Bearer header, OLLAMA_API_KEY = long literal
#   (Ollama Cloud; shapes are generic, never derived from a real key)
PATTERNS='sk-or-v1-[A-Za-z0-9]{40,}|AIzaSy[A-Za-z0-9_-]{30,}|sk-proj-[A-Za-z0-9_-]{20,}|sk-admin-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|BEGIN OPENSSH PRIVATE KEY|Authorization: Bearer [A-Za-z0-9._~+/=-]{20,}|OLLAMA_API_KEY["'\'' :=]+[A-Za-z0-9._+/-]{24,}'

# SPEC V24: any email address fails unless its domain is example.com, ends in .test, or
# the whole address is on ALLOWED_EMAILS. The allowlist is public repo addresses only
# (copyright in Info.plist and README.md, gh-pages committer in release.yml).
EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}'
ALLOWED_EMAILS='lazym0m3nt@gmail\.com|ci@github\.com'
# Where an address ends: an optional sentence period, then a character that is not a
# letter, digit, or dot. `-` ends it too, so `codex-…-a@example.com-plus.json` (a Codex
# auth file name) counts as example.com.
END='(\.?[^.A-Za-z0-9]|\.?$)'

scan() {
  grep -RIEn --include='*.swift' --include='*.plist' --include='*.yml' --include='*.json' --include='*.md' \
       "$1" AgentsUsageBar/ AgentsUsageBarTests/ .github/ .scratch/ docs/ README.md 2>/dev/null || true
}

FOUND=0

KEYS=$(scan "$PATTERNS")
if [ -n "$KEYS" ]; then
  echo "$KEYS"
  echo "Blocked: literal API key prefix found in source. See SEC-04."
  FOUND=1
fi

# Drop allowed addresses from each matching line, then flag any address left.
EMAILS=$(scan "$EMAIL" \
  | sed -E "s/(^|[^A-Za-z0-9._%+-])($ALLOWED_EMAILS)$END/\1<allowed>\3/g" \
  | sed -E "s/@example\.com$END/<allowed>\1/g; s/@[A-Za-z0-9.-]+\.test$END/<allowed>\1/g" \
  | grep -E "$EMAIL" || true)
if [ -n "$EMAILS" ]; then
  echo "$EMAILS"
  echo "Blocked: email address outside example.com, .test, and the allowlist. See SPEC V24."
  FOUND=1
fi

if [ "$FOUND" -eq 1 ]; then
  exit 1
fi

echo "OK: No literal API key prefixes or real email addresses."
