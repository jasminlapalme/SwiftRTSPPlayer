#!/bin/bash
# Bundles Frameworks/FFmpeg.xcframework into a zip, uploads it as an asset
# on a GitHub release (creating the release if needed), and rewrites the
# remote URL + checksum in Package.swift so consumers fetch the new build.
#
#   ./Scripts/release_ffmpeg.sh <tag> [title]
#
# Example:
#   ./Scripts/release_ffmpeg.sh ffmpeg-n8.1.1
#
# Requires: gh (GitHub CLI, authenticated), swift, zip.

set -euo pipefail

TAG="${1:?Usage: $0 <tag> [title]}"
TITLE="${2:-FFmpeg ${TAG}}"

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
FRAMEWORK="$ROOT/Frameworks/FFmpeg.xcframework"
ZIP="$ROOT/Frameworks/FFmpeg.xcframework.zip"
PACKAGE="$ROOT/Package.swift"

if [[ ! -d "$FRAMEWORK" ]]; then
	echo "Error: $FRAMEWORK not found. Run ./Scripts/build_ffmpeg.sh first." >&2
	exit 1
fi

for cmd in gh swift zip; do
	command -v "$cmd" >/dev/null || { echo "Error: '$cmd' is required." >&2; exit 1; }
done

echo "Zipping FFmpeg.xcframework..."
rm -f "$ZIP"
(cd "$ROOT/Frameworks" && zip -r -y -q "$(basename "$ZIP")" "FFmpeg.xcframework")

echo "Computing checksum..."
CHECKSUM="$(swift package --package-path "$ROOT" compute-checksum "$ZIP")"
echo "Checksum: $CHECKSUM"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
URL="https://github.com/$REPO/releases/download/$TAG/FFmpeg.xcframework.zip"

if gh release view "$TAG" >/dev/null 2>&1; then
	echo "Release $TAG already exists; uploading asset (overwriting)..."
	gh release upload "$TAG" "$ZIP" --clobber
else
	echo "Creating release $TAG..."
	gh release create "$TAG" "$ZIP" --title "$TITLE" --notes "FFmpeg.xcframework prebuilt for SwiftRTSPPlayer.

Checksum: \`$CHECKSUM\`"
fi

echo "Patching Package.swift..."
sed -i '' -E "s|url: \"https://github.com/[^\"]*FFmpeg\\.xcframework\\.zip\"|url: \"$URL\"|" "$PACKAGE"
sed -i '' -E "s|checksum: \"[a-f0-9]{64}\"|checksum: \"$CHECKSUM\"|" "$PACKAGE"

echo
echo "Done."
echo "  URL:      $URL"
echo "  Checksum: $CHECKSUM"
echo
echo "Review and commit Package.swift."
