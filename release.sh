#!/usr/bin/env bash
# Cut a Doppio release: build + zip, publish the GitHub release in the app repo,
# then bump the cask in the tap repo (relyweb/homebrew-doppio).
#
# Usage:  ./release.sh <version>     e.g.  ./release.sh 0.2.1
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
[[ -n "$VERSION" ]] || { echo "usage: $0 <version>   (e.g. 0.2.1)" >&2; exit 1; }

REPO="relyweb/doppio"
TAP_REPO="relyweb/homebrew-doppio"

echo "==> Setting bundle version to $VERSION in Info.plist ..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist
# Commit + push the bump before tagging, so the release tag captures this
# version (the About dialog reads CFBundleShortVersionString at runtime).
if git diff --quiet -- Info.plist; then
  echo "    already at $VERSION"
else
  git commit -q Info.plist -m "doppio $VERSION"
  git push -q origin HEAD:main
  echo "    committed + pushed Info.plist bump"
fi

echo "==> Building release artifact ..."
./build.sh >/dev/null
mkdir -p dist; rm -f dist/Doppio.zip
ditto -c -k --keepParent Doppio.app dist/Doppio.zip
SHA=$(shasum -a 256 dist/Doppio.zip | awk '{print $1}')
echo "    version=$VERSION sha256=$SHA"

echo "==> Publishing GitHub release v$VERSION in $REPO ..."
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "v$VERSION" dist/Doppio.zip --repo "$REPO" --clobber
else
  gh release create "v$VERSION" dist/Doppio.zip --repo "$REPO" \
    --title "Doppio v$VERSION" \
    --notes "Keep your Mac awake for agentic tasks. Install: brew tap relyweb/doppio && brew install --cask doppio"
fi

echo "==> Bumping cask in $TAP_REPO ..."
WORK=$(mktemp -d)
git clone --depth 1 "https://github.com/$TAP_REPO" "$WORK/tap" >/dev/null 2>&1
/usr/bin/sed -i '' \
  -e "s|^  version \".*\"|  version \"$VERSION\"|" \
  -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
  "$WORK/tap/Casks/doppio.rb"
git -C "$WORK/tap" commit -aqm "doppio $VERSION"
git -C "$WORK/tap" push -q origin HEAD:main
rm -rf "$WORK"

echo ""
echo "Released v$VERSION. Users get it with:"
echo "    brew tap relyweb/doppio"
echo "    brew install --cask doppio        (brew upgrade --cask doppio to update)"
