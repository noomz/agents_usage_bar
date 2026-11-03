#!/bin/sh
# Runs scripts/install.sh against file:// release fixtures built from cli/. Exits non-zero on the
# first wrong behavior.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
installer="$root/scripts/install.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/aub-check-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

bad() {
  printf 'check-install: %s\n' "$1" >&2
  exit 1
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

(cd "$root/cli" && CGO_ENABLED=0 go build -o "$work/aub" ./cmd/aub)
tarball="aub-$(cd "$root/cli" && go env GOOS)-$(cd "$root/cli" && go env GOARCH).tar.gz"

good="$work/good"
mkdir -p "$good"
tar -czf "$good/$tarball" -C "$work" aub
printf '%s  %s\n' "$(sha256_of "$good/$tarball")" "$tarball" >"$good/aub-checksums.txt"

tampered="$work/tampered"
mkdir -p "$tampered"
cp "$good/$tarball" "$tampered/$tarball"
printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "$tarball" >"$tampered/aub-checksums.txt"

dest="$work/bin"
AUB_RELEASE_URL="file://$good" AUB_INSTALL_DIR="$dest" sh "$installer" >/dev/null
"$dest/aub" --version >/dev/null || bad "the installed binary does not run"
[ "$(find "$dest" -type f | wc -l | tr -d ' ')" = 1 ] || bad "the install left extra files"
echo "pass: installs and runs"

dest2="$work/bin2"
AUB_RELEASE_URL="file://$good" AUB_INSTALL_DIR="$dest2" sh <"$installer" >/dev/null
[ -x "$dest2/aub" ] || bad "a piped install did nothing"
echo "pass: installs from a pipe"

dest3="$work/bin3"
if AUB_RELEASE_URL="file://$tampered" AUB_INSTALL_DIR="$dest3" sh "$installer" >"$work/out" 2>&1; then
  bad "a checksum mismatch exited 0"
fi
grep -q "checksum mismatch" "$work/out" || bad "a checksum mismatch printed the wrong error"
[ ! -e "$dest3/aub" ] || bad "a checksum mismatch installed the binary"
echo "pass: checksum mismatch installs nothing"

before="$(sha256_of "$dest/aub")"
if AUB_RELEASE_URL="file://$tampered" AUB_INSTALL_DIR="$dest" sh "$installer" >/dev/null 2>&1; then
  bad "a checksum mismatch over an install exited 0"
fi
[ "$(sha256_of "$dest/aub")" = "$before" ] || bad "a checksum mismatch replaced the installed binary"
echo "pass: checksum mismatch keeps the installed binary"

size="$(wc -c <"$installer" | tr -d ' ')"
offset=100
while [ "$offset" -lt "$size" ]; do
  cut_dest="$work/cut-$offset"
  head -c "$offset" "$installer" | AUB_RELEASE_URL="file://$good" AUB_INSTALL_DIR="$cut_dest" sh >/dev/null 2>&1 || true
  [ ! -e "$cut_dest" ] || bad "a script cut at byte $offset of $size still installed"
  offset=$((offset + 100))
done
echo "pass: a truncated script installs nothing"
