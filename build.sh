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
