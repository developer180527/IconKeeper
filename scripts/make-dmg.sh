#!/bin/bash
#
# Builds IconKeeper (Release) and packages it into a styled, compressed DMG.
#
#   scripts/make-dmg.sh              # version from the project's MARKETING_VERSION
#   SKIP_BUILD=1 APP=path/IconKeeper.app scripts/make-dmg.sh
#   SIGN_IDENTITY="Apple Development: …" scripts/make-dmg.sh   # sign the DMG too
#
# Requires: Xcode, create-dmg (brew install create-dmg).
# Output:   dist/IconKeeper-<version>.dmg

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v create-dmg >/dev/null || { echo "create-dmg not found: brew install create-dmg" >&2; exit 1; }

VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' IconKeeper.xcodeproj/project.pbxproj | head -1)}"
WORK="$(mktemp -d -t iconkeeper-dmg)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p dist
OUT="dist/IconKeeper-$VERSION.dmg"

# 1. Build
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Building IconKeeper $VERSION (Release)"
  xcodebuild -project IconKeeper.xcodeproj -scheme IconKeeper -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$WORK/build" clean build \
    | grep -E "error:|warning: .*IconKeeper/|BUILD" || true
  APP="$WORK/build/Build/Products/Release/IconKeeper.app"
fi
APP="${APP:?set APP to an IconKeeper.app}"
[[ -d "$APP" ]] || { echo "App not found at $APP" >&2; exit 1; }
BUILT_VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
[[ "$BUILT_VERSION" == "$VERSION" ]] || { echo "App is $BUILT_VERSION, expected $VERSION" >&2; exit 1; }

# 2. Artwork (1x + 2x merged into one HiDPI TIFF)
echo "==> Rendering background"
swift scripts/dmg/render-background.swift "$WORK" >/dev/null
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null

# 3. Stage and package. Icon positions match render-background.swift.
mkdir -p "$WORK/stage"
ditto "$APP" "$WORK/stage/IconKeeper.app"
rm -f "$OUT"
echo "==> Creating $OUT"
create-dmg \
  --volname "IconKeeper $VERSION" \
  --volicon "Assets/IconKeeper.icns" \
  --background "$WORK/background.tiff" \
  --window-pos 240 160 \
  --window-size 660 440 \
  --text-size 13 \
  --icon-size 112 \
  --icon "IconKeeper.app" 170 215 \
  --hide-extension "IconKeeper.app" \
  --app-drop-link 490 215 \
  --no-internet-enable \
  --format UDZO \
  --filesystem APFS \
  "$OUT" "$WORK/stage" >/dev/null

# 4. Optional signature on the image itself
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing DMG"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$OUT"
fi

hdiutil verify "$OUT" >/dev/null
echo "==> Done: $OUT ($(du -h "$OUT" | cut -f1))"
