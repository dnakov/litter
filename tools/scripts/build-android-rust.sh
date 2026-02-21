#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRIDGE_DIR="$REPO_DIR/shared/rust-bridge/codex-bridge"
OUT_DIR="$REPO_DIR/apps/android/core/bridge/src/main/jniLibs"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo is required" >&2
  exit 1
fi

if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "error: cargo-ndk is required (install with: cargo install cargo-ndk)" >&2
  exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  echo "error: set ANDROID_NDK_HOME or ANDROID_NDK_ROOT" >&2
  exit 1
fi

echo "==> Installing Android Rust targets..."
rustup target add aarch64-linux-android x86_64-linux-android

mkdir -p "$OUT_DIR"

echo "==> Building codex_bridge Android shared libs..."
cd "$BRIDGE_DIR"
cargo ndk -t arm64-v8a -t x86_64 -o "$OUT_DIR" build --release

echo "==> Done. Android JNI libs are in: $OUT_DIR"
