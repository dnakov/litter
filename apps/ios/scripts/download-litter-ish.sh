#!/usr/bin/env bash
# Download + extract litter-ish artifacts (iSH xcframework + Alpine fakefs)
# from a GitHub release of dnakov/litter-ish, pinned by version.
#
# Usage:
#   LITTER_ISH_VERSION=v0.1.0 ./apps/ios/scripts/download-litter-ish.sh
#
# Outputs:
#   apps/ios/Frameworks/litter_ish.xcframework/    (linked + embedded)
#   apps/ios/Resources/fs/               (bundled as Resource)

set -euo pipefail

VERSION="${LITTER_ISH_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    echo "error: LITTER_ISH_VERSION must be set (e.g. v0.1.0)" >&2
    exit 1
fi

REPO="dnakov/litter-ish"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
RESOURCES_DIR="$IOS_DIR/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
XCF_TGZ="litter_ish.xcframework.tar.gz"
FAKEFS_TGZ="fs.tar.gz"
SUMS="SHA256SUMS"

fetch() {
    local name="$1"
    echo "==> Downloading $name"
    curl -fsSL --retry 3 -o "$TMP_DIR/$name" "$BASE_URL/$name"
}

fetch "$XCF_TGZ"
fetch "$FAKEFS_TGZ"
fetch "$SUMS"

echo "==> Verifying checksums"
( cd "$TMP_DIR" && shasum -a 256 -c "$SUMS" )

echo "==> Installing litter_ish.xcframework"
rm -rf "$FRAMEWORKS_DIR/litter_ish.xcframework"
mkdir -p "$FRAMEWORKS_DIR"
tar -xzf "$TMP_DIR/$XCF_TGZ" -C "$FRAMEWORKS_DIR"

echo "==> Installing fs"
rm -rf "$RESOURCES_DIR/fs"
mkdir -p "$RESOURCES_DIR"
tar -xzf "$TMP_DIR/$FAKEFS_TGZ" -C "$RESOURCES_DIR"

echo
echo "litter-ish $VERSION installed:"
du -sh "$FRAMEWORKS_DIR/litter_ish.xcframework" "$RESOURCES_DIR/fs"
