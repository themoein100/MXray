#!/usr/bin/env bash
#
# Cuts a new MXray release when LibXray.xcframework has been rebuilt upstream.
#
# It zips the framework, computes the SwiftPM checksum, rewrites the url + checksum
# in Package.swift, commits and pushes that change, then creates the GitHub release
# and uploads the zip as its asset — all in one shot.
#
# Usage:
#   Scripts/release.sh <version> [path/to/LibXray.xcframework]
#
# Examples:
#   Scripts/release.sh 1.0.1
#   Scripts/release.sh 1.1.0 ~/libXray-apple/LibXray.xcframework
#
# Requirements: git, gh (authenticated), swift, ditto.

set -euo pipefail

# --- args ------------------------------------------------------------------
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: Scripts/release.sh <version> [path/to/LibXray.xcframework]" >&2
  exit 1
fi
# Strip a leading "v" if the user typed it, we add it back for the tag.
VERSION="${VERSION#v}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like 1.2.3 (got '$VERSION')" >&2
  exit 1
fi
TAG="v$VERSION"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="${2:-$REPO_ROOT/Frameworks/LibXray.xcframework}"
ZIP="$REPO_ROOT/Frameworks/LibXray.xcframework.zip"
PACKAGE="$REPO_ROOT/Package.swift"
ASSET_URL="https://github.com/themoein100/MXray/releases/download/$TAG/LibXray.xcframework.zip"

# --- sanity checks ---------------------------------------------------------
command -v gh    >/dev/null || { echo "error: gh CLI not found"; exit 1; }
command -v swift >/dev/null || { echo "error: swift not found"; exit 1; }
[[ -e "$XCFRAMEWORK" ]] || { echo "error: xcframework not found: $XCFRAMEWORK"; exit 1; }

if git -C "$REPO_ROOT" rev-parse "$TAG" >/dev/null 2>&1; then
  echo "error: tag $TAG already exists. Bump the version." >&2
  exit 1
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- "$PACKAGE")" ]]; then
  echo "error: Package.swift has uncommitted changes; commit or stash first." >&2
  exit 1
fi

# --- 1. zip + checksum -----------------------------------------------------
echo "▸ Zipping $XCFRAMEWORK …"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK" "$ZIP"
CHECKSUM="$(swift package --package-path "$REPO_ROOT" compute-checksum "$ZIP")"
echo "  size:     $(du -h "$ZIP" | cut -f1)"
echo "  checksum: $CHECKSUM"

# --- 2. rewrite Package.swift ---------------------------------------------
echo "▸ Updating Package.swift (url → $TAG, checksum)…"
# Update the release download version in the binaryTarget url.
sed -i '' -E "s#(releases/download/)v[0-9]+\.[0-9]+\.[0-9]+(/LibXray\.xcframework\.zip)#\1$TAG\2#" "$PACKAGE"
# Update the checksum string. Matches the first 64-hex checksum literal.
sed -i '' -E "s#(checksum: \")[0-9a-f]{64}(\")#\1$CHECKSUM\2#" "$PACKAGE"

# Verify the edits landed.
grep -q "$TAG/LibXray.xcframework.zip" "$PACKAGE" || { echo "error: url not updated in Package.swift"; exit 1; }
grep -q "$CHECKSUM" "$PACKAGE"                    || { echo "error: checksum not updated in Package.swift"; exit 1; }

# --- 3. commit + push ------------------------------------------------------
echo "▸ Committing and pushing Package.swift…"
git -C "$REPO_ROOT" add "$PACKAGE"
git -C "$REPO_ROOT" commit -m "Release $TAG: update LibXray binary to $CHECKSUM"
git -C "$REPO_ROOT" push origin HEAD

# --- 4. create the GitHub release -----------------------------------------
echo "▸ Creating GitHub release $TAG and uploading the asset…"
gh release create "$TAG" \
  --repo themoein100/MXray \
  --title "MXray $TAG" \
  --notes "Automated release. LibXray.xcframework rebuilt.

Consume with:
\`\`\`swift
.package(url: \"https://github.com/themoein100/MXray.git\", from: \"$VERSION\")
\`\`\`

LibXray.xcframework.zip SwiftPM checksum:
\`$CHECKSUM\`" \
  "$ZIP"

echo
echo "✅ Released $TAG"
echo "   $ASSET_URL"
