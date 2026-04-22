#!/usr/bin/env bash
# Download Android arm64 CLI binaries for the on-device Codex agent.
#
# Source: bnsmb/binaries-for-Android pinned to a specific commit SHA so the
# downloaded artifacts can't shift under us. Binaries are placed under
# `apps/android/app/src/main/jniLibs/arm64-v8a/lib<tool>.so`; the package
# installer extracts them into the app's `nativeLibraryDir`, which is the
# only execute-allowed location in the app sandbox on Android 10+.
#
# Tools we don't bundle (`ls`, `cat`, `grep`, `sed`, `awk`, etc.) are already
# present at `/system/bin` on every Android device and resolve via PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEST="$REPO_DIR/apps/android/app/src/main/jniLibs/arm64-v8a"

PIN_SHA="728fde6d326ccc80b87b87305de919afd5891f37"
BASE_URL="https://raw.githubusercontent.com/bnsmb/binaries-for-Android/${PIN_SHA}/binaries"

# Format: <local-name>:<remote-name>:<sha256>
TOOLS=(
    "libcurl.so:curl-8.19.0:7331475099de07acc8e5d0ec8139e35394f65d5fb596d9411ef7a46eb44b7bde"
    "libwget.so:wget2:a8468065b605f87e2af5bd782e36bc7fac0e6cf3e5678699fc8f282658066be1"
)

if ! command -v curl >/dev/null 2>&1; then
    echo "error: curl is required" >&2
    exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
    echo "error: sha256sum is required" >&2
    exit 1
fi

mkdir -p "$DEST"

for entry in "${TOOLS[@]}"; do
    IFS=':' read -r local_name remote_name expected_sha <<<"$entry"
    target="$DEST/$local_name"

    if [ -f "$target" ]; then
        actual_sha="$(sha256sum "$target" | awk '{print $1}')"
        if [ "$actual_sha" = "$expected_sha" ]; then
            echo "==> $local_name already present, skipping (sha256 ok)"
            continue
        fi
        echo "==> $local_name has mismatched sha256, re-downloading"
    fi

    echo "==> Downloading $local_name <- $remote_name"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    curl -fsSL "$BASE_URL/$remote_name" -o "$tmp"
    actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        echo "error: sha256 mismatch for $remote_name" >&2
        echo "  expected: $expected_sha" >&2
        echo "  actual:   $actual_sha" >&2
        rm -f "$tmp"
        exit 1
    fi
    chmod +x "$tmp"
    mv "$tmp" "$target"
    trap - EXIT
    echo "    placed at $target ($(stat -c '%s' "$target") bytes)"
done

echo "==> Android CLI tools ready in $DEST/"
