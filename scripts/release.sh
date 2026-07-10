#!/bin/bash
# Builds LLMUsageBar.app and publishes it as a GitHub release.
# Usage: scripts/release.sh <version>   e.g. scripts/release.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> (e.g. 1.1.0)}"
TAG="v$VERSION"

# The tag must describe exactly what gets built.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree not clean — commit or stash first" >&2
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi

# Stamp the version into the app bundle.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Resources/Info.plist
if [ -n "$(git status --porcelain Resources/Info.plist)" ]; then
    git add Resources/Info.plist
    git commit -m "chore: bump version to $VERSION"
fi

./build.sh

# ditto preserves the bundle structure and extended attributes plain zip drops.
ZIP="dist/LLMUsageBar-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent dist/LLMUsageBar.app "$ZIP"

git tag "$TAG"
git push origin HEAD "$TAG"

gh release create "$TAG" "$ZIP" \
    --title "LLMUsageBar $VERSION" \
    --generate-notes

echo ""
echo "Published: $(gh release view "$TAG" --json url -q .url)"
