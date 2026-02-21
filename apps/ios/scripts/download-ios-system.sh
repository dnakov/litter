#!/usr/bin/env bash
# Download ios_system xcframeworks (device + simulator) without perl/perlA/perlB,
# which have no simulator slice. perl is unused by codex anyway.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$SCRIPT_DIR/../Frameworks/ios_system"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

BASE="https://github.com/holzschu/ios_system/releases/download/v3.0.4"

download() {
    local name="$1"
    if [ -d "$DEST/$name.xcframework" ]; then
        echo "==> $name.xcframework already present, skipping"
        return
    fi
    echo "==> Downloading $name.xcframework..."
    curl -fsSL "$BASE/$name.xcframework.zip" -o "$TMP/$name.zip"
    unzip -q "$TMP/$name.zip" -d "$DEST"
    echo "    done"
}

# Core dispatcher — must come first
download ios_system
# Basic Unix commands (ls, cat, cp, mv, rm, mkdir, …)
download shell
# Text processing (grep, sed, wc, sort, uniq, …)
download text
# File commands (find, stat, …)
download files

echo "==> ios_system xcframeworks ready in $DEST/"
