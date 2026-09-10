#!/usr/bin/env bash
# Fail if a Mach-O (the aub / AgentsUsageBar binary) was built with LLVM
# source-based coverage instrumentation. Instrumented binaries dump
# default.profraw into the caller's cwd on every exit (GitHub issue #8).
#
# Usage: bash scripts/check-no-coverage.sh path/to/AgentsUsageBar
set -euo pipefail

if [ "${1:-}" = "" ]; then
  echo "usage: $0 path/to/binary" >&2
  exit 2
fi

BINARY="$1"
if [ ! -f "$BINARY" ]; then
  echo "error: not a file: $BINARY" >&2
  exit 1
fi

# grep -a: treat the Mach-O as text so the needle is found in either slice
# of a universal binary. -F: literal. __llvm_prf is the profile-data prefix
# (cnts / names / data) emitted by -fprofile-instr-generate.
if LC_ALL=C grep -a -F -q '__llvm_prf' "$BINARY"; then
  echo "error: $BINARY is coverage-instrumented (contains __llvm_prf)." >&2
  echo "       Build Release without -enableCodeCoverage / Gather coverage data." >&2
  exit 1
fi

echo "OK: $BINARY is not coverage-instrumented."
