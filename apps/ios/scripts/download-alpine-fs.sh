#!/usr/bin/env bash
# Download + extract the Alpine fakefs rootfs from a GitHub release of
# dnakov/litter-ish, pinned by version. The iSH kernel itself is now
# compiled from the `ish` Rust crate; only the rootfs tarball still ships
# as a prebuilt artifact.
#
# Usage:
#   ALPINE_FS_VERSION=v0.1.0 ./apps/ios/scripts/download-alpine-fs.sh
#
# Outputs:
#   apps/ios/Resources/fs/               (bundled as Resource)

set -euo pipefail

VERSION="${ALPINE_FS_VERSION:-}"
if [[ -z "$VERSION" ]]; then
    echo "error: ALPINE_FS_VERSION must be set (e.g. v0.1.0)" >&2
    exit 1
fi

REPO="dnakov/litter-ish"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES_DIR="$IOS_DIR/Resources"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BASE_URL="https://github.com/$REPO/releases/download/$VERSION"
FAKEFS_TGZ="fs.tar.gz"
SUMS="SHA256SUMS"

fetch() {
    local name="$1"
    echo "==> Downloading $name"
    curl -fsSL --retry 3 -o "$TMP_DIR/$name" "$BASE_URL/$name"
}

fetch "$FAKEFS_TGZ"
fetch "$SUMS"

echo "==> Verifying checksum for $FAKEFS_TGZ"
( cd "$TMP_DIR" && grep " $FAKEFS_TGZ\$" "$SUMS" | shasum -a 256 -c - )

echo "==> Installing fs"
rm -rf "$RESOURCES_DIR/fs"
mkdir -p "$RESOURCES_DIR"
tar -xzf "$TMP_DIR/$FAKEFS_TGZ" -C "$RESOURCES_DIR"

echo
echo "alpine-fs $VERSION installed:"
du -sh "$RESOURCES_DIR/fs"
