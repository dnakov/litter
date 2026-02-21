#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/codex"
PATCH_FILE="$REPO_DIR/patches/codex/ios-exec-hook.patch"

echo "==> Syncing codex submodule..."
git -C "$REPO_DIR" submodule update --init --recursive shared/third_party/codex

if [ ! -f "$PATCH_FILE" ]; then
    echo "error: missing patch file: $PATCH_FILE" >&2
    exit 1
fi

if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    echo "==> iOS hook patch already applied."
else
    echo "==> Applying iOS hook patch to submodule..."
    git -C "$SUBMODULE_DIR" apply --3way "$PATCH_FILE"
fi

echo "==> codex submodule ready at $(git -C "$SUBMODULE_DIR" rev-parse --short HEAD)"
