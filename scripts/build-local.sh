#!/usr/bin/env bash
#
# build-local.sh — Build AgentsUsageBar for LOCAL use (no Apple cert).
#
# Produces an ad-hoc-signed Release .app and installs it to ~/Applications.
# No Developer ID, no notarization, no Gatekeeper prompt (quarantine stripped).
#
# Why ad-hoc WITHOUT hardened runtime (`--options runtime`):
#   Hardened runtime enables library validation, which requires every loaded
#   framework to share the main binary's Team ID. Ad-hoc signatures ("-") carry
#   no Team ID, so the bundled Sparkle.framework gets rejected at launch with
#   "different Team IDs" and the app dies in dyld. Dropping the runtime flag
#   disables library validation and the ad-hoc Sparkle helpers load fine.
#   (The CI release workflow keeps `--options runtime` because its SIGNED lane
#   uses a real Developer ID cert, where library validation is satisfied.)
#
# Usage:  ./scripts/build-local.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="AgentsUsageBar"
PROJECT="AgentsUsageBar.xcodeproj"
DD="build/dd"
APP="$DD/Build/Products/Release/$SCHEME.app"
DEST="$HOME/Applications/$SCHEME.app"

echo "==> Building $SCHEME (Release, no signing)…"
rm -rf "$DD"
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DD" \
  -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CLANG_COVERAGE_MAPPING=NO \
  ENABLE_CODE_COVERAGE=NO

test -d "$APP"
bash scripts/check-no-coverage.sh "$APP/Contents/MacOS/$SCHEME"

echo "==> Ad-hoc signing (nested helpers first, no hardened runtime)…"
# `find ... -depth` yields children before parents so each nested XPC/app/
# framework is sealed before the outer bundle signs over it.
while IFS= read -r item; do
  codesign --force --sign - "$item"
done < <(find "$APP/Contents" \
           \( -name '*.xpc' -o -name '*.app' -o -name '*.framework' \) \
           -depth)
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Installing to ${DEST}…"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"

echo "==> Done. Installed $SCHEME $VERSION → $DEST"
echo "    Launch:  open \"$DEST\""
echo "    (menu bar app — icon appears top-right, no Dock icon / window)"
