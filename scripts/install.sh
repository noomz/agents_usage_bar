#!/bin/sh
#
# install.sh: install the aub CLI from GitHub Releases. Needs no app and no sudo, and changes no
# shell config.
#
#   curl -fsSL https://raw.githubusercontent.com/noomz/agents_usage_bar/main/scripts/install.sh | sh
#
# Env:
#   AUB_INSTALL_DIR  target directory (default: ~/.local/bin)
#   AUB_VERSION      release tag such as v0.1.28 (default: the latest release)
#   AUB_RELEASE_URL  base URL that holds the release files (default: this repo's GitHub Releases)

set -eu

repo_url="https://github.com/noomz/agents_usage_bar/releases"
checksums_name="aub-checksums.txt"

fail() {
  printf 'aub install: %s\n' "$1" >&2
  exit 1
}

detect_os() {
  case "$(uname -s)" in
    Linux) echo linux ;;
    Darwin) echo darwin ;;
    *) fail "unsupported operating system: $(uname -s)" ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) echo amd64 ;;
    aarch64 | arm64) echo arm64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
}

download() { # url destination
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1" -o "$2"
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$1" -O "$2"
  else
    fail "needs curl or wget"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "needs sha256sum or shasum"
  fi
}

os="$(detect_os)"
arch="$(detect_arch)"
tarball="aub-$os-$arch.tar.gz"

if [ -n "${AUB_RELEASE_URL:-}" ]; then
  base="$AUB_RELEASE_URL"
elif [ -n "${AUB_VERSION:-}" ]; then
  base="$repo_url/download/$AUB_VERSION"
else
  base="$repo_url/latest/download"
fi

[ -n "${HOME:-}" ] || [ -n "${AUB_INSTALL_DIR:-}" ] || fail "HOME is not set; set AUB_INSTALL_DIR"
install_dir="${AUB_INSTALL_DIR:-$HOME/.local/bin}"
target="$install_dir/aub"
[ ! -d "$target" ] || fail "$target is a directory"

staged=""
work="$(mktemp -d "${TMPDIR:-/tmp}/aub-install.XXXXXX")"
trap 'rm -rf "$work"; [ -z "$staged" ] || rm -f "$staged"' EXIT
trap 'exit 1' HUP INT TERM

download "$base/$tarball" "$work/$tarball" || fail "no release file for $os/$arch: $base/$tarball"
download "$base/$checksums_name" "$work/$checksums_name" || fail "no checksums file: $base/$checksums_name"

expected="$(awk -v name="$tarball" '$2 == name || $2 == "*" name {print $1}' "$work/$checksums_name")"
[ -n "$expected" ] || fail "$checksums_name has no entry for $tarball"
actual="$(sha256_of "$work/$tarball")"
[ "$expected" = "$actual" ] || fail "checksum mismatch for $tarball: expected $expected, got $actual. Nothing was installed."

tar -xzf "$work/$tarball" -C "$work" aub || fail "$tarball does not contain aub"
chmod 755 "$work/aub"
version="$("$work/aub" --version)" || fail "the downloaded binary does not run on this machine"

mkdir -p "$install_dir" || fail "cannot create $install_dir"
staged="$(mktemp "$install_dir/.aub.XXXXXX")" || fail "cannot write to $install_dir"
cp "$work/aub" "$staged"
chmod 755 "$staged"

# mv replaces a symlink itself, so a link into the macOS app never overwrites the app's binary.
if [ -L "$target" ]; then
  printf 'Replaced aub → %s\n' "$(readlink "$target")"
fi
mv -f "$staged" "$target"
printf 'Installed %s → %s\n' "$version" "$target"

case ":${PATH:-}:" in
  *":$install_dir:"*) ;;
  *)
    if [ "$install_dir" = "${HOME:-}/.local/bin" ]; then
      printf '%s\n' 'Not on PATH. fish: fish_add_path ~/.local/bin   zsh/bash: export PATH="$HOME/.local/bin:$PATH"'
    else
      printf 'Not on PATH. Add %s to PATH in your shell profile.\n' "$install_dir"
    fi
    ;;
esac
