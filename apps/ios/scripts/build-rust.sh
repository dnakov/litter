#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
BRIDGE_DIR="$REPO_DIR/shared/rust-bridge/codex-bridge"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"

mkdir -p "$FRAMEWORKS_DIR"

echo "==> Preparing codex submodule..."
"$SCRIPT_DIR/sync-codex.sh"

cd "$BRIDGE_DIR"

echo "==> Installing iOS targets..."
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios

echo "==> Building for aarch64-apple-ios (device)..."
cargo rustc --release --target aarch64-apple-ios --crate-type staticlib

echo "==> Building for aarch64-apple-ios-sim (Apple Silicon simulator)..."
cargo rustc --release --target aarch64-apple-ios-sim --crate-type staticlib

echo "==> Building for x86_64-apple-ios (Intel simulator)..."
cargo rustc --release --target x86_64-apple-ios --crate-type staticlib

echo "==> Creating fat simulator lib..."
mkdir -p target/ios-sim-fat/release
lipo -create \
  target/aarch64-apple-ios-sim/release/libcodex_bridge.a \
  target/x86_64-apple-ios/release/libcodex_bridge.a \
  -output target/ios-sim-fat/release/libcodex_bridge.a

echo "==> Creating xcframework..."
rm -rf "$FRAMEWORKS_DIR/codex_bridge.xcframework"
xcodebuild -create-xcframework \
  -library target/aarch64-apple-ios/release/libcodex_bridge.a \
  -headers include/ \
  -library target/ios-sim-fat/release/libcodex_bridge.a \
  -headers include/ \
  -output "$FRAMEWORKS_DIR/codex_bridge.xcframework"

echo "==> Done: $FRAMEWORKS_DIR/codex_bridge.xcframework"
