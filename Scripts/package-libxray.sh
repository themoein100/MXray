#!/usr/bin/env bash
#
# Packages LibXray.xcframework into a zip and prints its SwiftPM checksum,
# ready to upload as a GitHub Release asset for the `.binaryTarget(url:checksum:)`.
#
# Usage:
#   Scripts/package-libxray.sh [path/to/LibXray.xcframework]
#
# Defaults to Frameworks/LibXray.xcframework relative to the repo root.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XCFRAMEWORK="${1:-$REPO_ROOT/Frameworks/LibXray.xcframework}"
OUTPUT="$REPO_ROOT/Frameworks/LibXray.xcframework.zip"

if [[ ! -d "$XCFRAMEWORK" ]]; then
  echo "error: xcframework not found at: $XCFRAMEWORK" >&2
  exit 1
fi

echo "Zipping $XCFRAMEWORK …"
rm -f "$OUTPUT"
ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK" "$OUTPUT"

echo
echo "Created: $OUTPUT"
echo "Size:    $(du -h "$OUTPUT" | cut -f1)"
echo
echo "SwiftPM checksum:"
swift package --package-path "$REPO_ROOT" compute-checksum "$OUTPUT"
echo
echo "Next: upload the zip to a GitHub Release and set the url + checksum in Package.swift."
