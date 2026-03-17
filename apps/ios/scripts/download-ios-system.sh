#!/usr/bin/env bash
# Download ios_system xcframeworks (device + simulator).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$SCRIPT_DIR/../Frameworks/ios_system"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$DEST"

IOS_SYSTEM_BASE="https://github.com/holzschu/ios_system/releases/download/v3.0.4"
LG2_BASE="https://github.com/holzschu/libgit2/releases/download/ios_1.0"
OPENSSL_BASE="https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w"
LIBSSH2_BASE="https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0"

download() {
    local name="$1"
    local base="${2:-$IOS_SYSTEM_BASE}"
    if [ -d "$DEST/$name.xcframework" ]; then
        echo "==> $name.xcframework already present, skipping"
        return
    fi
    echo "==> Downloading $name.xcframework..."
    curl -fsSL "$base/$name.xcframework.zip" -o "$TMP/$name.zip"
    unzip -q "$TMP/$name.zip" -d "$DEST"
    echo "    done"
}

# ── Core ──────────────────────────────────────────────────────────────
download ios_system

# ── Unix commands ─────────────────────────────────────────────────────
download shell          # ls, cat, cp, mv, rm, mkdir, chmod, ...
download text           # grep, sed, wc, sort, uniq, head, tail, tr, ...
download files          # find, stat, du, ...
download awk            # awk
download tar            # tar

# ── Network ───────────────────────────────────────────────────────────
download curl_ios       # curl
download ssh_cmd        # ssh, scp, sftp

# ── Git ───────────────────────────────────────────────────────────────
download lg2 "$LG2_BASE"  # git (libgit2 CLI wrapper)

# ── OpenSSL (required by Python and SSH) ──────────────────────────────
download_named() {
    local name="$1"
    local url="$2"
    if [ -d "$DEST/$name.xcframework" ]; then
        echo "==> $name.xcframework already present, skipping"
        return
    fi
    echo "==> Downloading $name.xcframework..."
    curl -fsSL "$url" -o "$TMP/$name.zip"
    unzip -q "$TMP/$name.zip" -d "$DEST"
    echo "    done"
}
download_named openssl "$OPENSSL_BASE/openssl-dynamic.xcframework.zip"
download_named libssh2 "$LIBSSH2_BASE/libssh2-dynamic.xcframework.zip"


echo "==> ios_system xcframeworks ready in $DEST/"
