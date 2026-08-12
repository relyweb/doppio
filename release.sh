#!/usr/bin/env bash
# Cut a Doppio release and publish it so `brew install` works.
#
# Steps:
#   1. Build Doppio.app and zip it (dist/Doppio.zip).
#   2. Update Casks/doppio.rb with the new version + sha256.
#   3. Create/replace the GitHub release "v<version>" and upload the zip.
#
# Usage:  ./release.sh <version>        e.g.  ./release.sh 0.0.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   (e.g. 0.0.1)" >&2
  exit 1
fi

REPO="relyweb/doppio"
CASK="Casks/doppio.rb"

echo "==> Building release artifact ..."
./build.sh >/dev/null
mkdir -p dist
rm -f dist/Doppio.zip
ditto -c -k --keepParent Doppio.app dist/Doppio.zip
SHA=$(shasum -a 256 dist/Doppio.zip | awk '{print $1}')
echo "    version=$VERSION sha256=$SHA"

echo "==> Updating $CASK ..."
/usr/bin/sed -i '' \
  -e "s|^  version \".*\"|  version \"$VERSION\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$CASK"

echo "==> Publishing GitHub release v$VERSION ..."
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" dist/Doppio.zip --repo "$REPO" --clobber
else
  gh release create "v$VERSION" dist/Doppio.zip \
    --repo "$REPO" \
    --title "Doppio v$VERSION" \
    --notes "Keep your Mac awake for agentic tasks. Install: brew install relyweb/doppio/doppio"
fi

echo ""
echo "Released v$VERSION."
echo "Commit the updated $CASK, then users can:"
echo "    brew tap relyweb/doppio https://github.com/$REPO"
echo "    brew install --cask doppio"
