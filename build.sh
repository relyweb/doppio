#!/usr/bin/env bash
# Build Doppio.app — a menu-bar agent that keeps macOS awake for agentic tasks.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Doppio"
BUNDLE="${APP_NAME}.app"
CONFIG="release"

echo "==> Compiling ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built binary not found at $BIN_PATH" >&2
  exit 1
fi

echo "==> Assembling ${BUNDLE} ..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp Info.plist "$BUNDLE/Contents/Info.plist"

# App icon. Regenerate the .icns from the SVG source if it is missing and a
# rasterizer is available; otherwise use the committed one.
if [[ ! -f Resources/AppIcon.icns ]] && command -v rsvg-convert >/dev/null 2>&1; then
  echo "==> Regenerating AppIcon.icns from SVG ..."
  ICONSET=Resources/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
              "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
              "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
    set -- $spec
    rsvg-convert -w "$1" -h "$1" Resources/AppIcon.svg -o "$ICONSET/$2.png"
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
else
  echo "warning: Resources/AppIcon.icns missing; app will have no custom icon."
fi

# Ad-hoc codesign so the bundle has a stable identity (required for the
# "Start at Login" SMAppService registration to work).
echo "==> Ad-hoc signing ..."
codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || \
  echo "warning: codesign failed; 'Start at Login' may not work until signed."

echo ""
echo "Built $BUNDLE"
echo ""
echo "Run it:            open ./$BUNDLE"
echo "Install it:        cp -R ./$BUNDLE /Applications/ && open /Applications/$BUNDLE"
echo "Verify assertion:  \"$BUNDLE/Contents/MacOS/$APP_NAME\" --selftest"
