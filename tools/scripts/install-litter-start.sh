#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_PATH="$ROOT_DIR/litter-start"
TARGET_DIR="${LITTER_START_BIN_DIR:-$HOME/.local/bin}"
TARGET_PATH="$TARGET_DIR/litter-start"

usage() {
  cat <<EOF
Usage: $0 [--bin-dir DIR]

Creates a symlink so \`litter-start\` is available on your PATH.

Options:
  --bin-dir DIR   Install into DIR instead of \$HOME/.local/bin
  -h, --help      Show this help text
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir)
      TARGET_DIR="$2"
      TARGET_PATH="$TARGET_DIR/litter-start"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

mkdir -p "$TARGET_DIR"
ln -sfn "$SOURCE_PATH" "$TARGET_PATH"

echo "Installed litter-start -> $SOURCE_PATH"
echo "  Symlink: $TARGET_PATH"

case ":$PATH:" in
  *":$TARGET_DIR:"*)
    echo "  PATH: ready"
    ;;
  *)
    echo "  PATH: add $TARGET_DIR to your shell PATH before using litter-start directly"
    ;;
esac
