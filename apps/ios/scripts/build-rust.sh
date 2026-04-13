#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
source "$REPO_DIR/tools/scripts/load-sccache-aws-creds.sh"
RUST_BRIDGE_DIR="$REPO_DIR/shared/rust-bridge"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
GENERATED_SWIFT_DIR="$RUST_BRIDGE_DIR/generated/swift"
UNIFFI_OUT="$IOS_DIR/Sources/Litter/Bridge/UniFFICodexClient.generated.swift"
GENERATED_RUST_DIR="$IOS_DIR/GeneratedRust"
GENERATED_HEADERS_DIR="$GENERATED_RUST_DIR/Headers"
GENERATED_DEVICE_DIR="$GENERATED_RUST_DIR/ios-device"
GENERATED_SIM_DIR="$GENERATED_RUST_DIR/ios-sim"
BINDINGS_HASH_FILE="$GENERATED_RUST_DIR/.swift-bindings.hash"
IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-18.0}"
SUBMODULE_DIR="$REPO_DIR/shared/third_party/codex"
IOS_CLANGXX_WRAPPER="$SCRIPT_DIR/ios-clangxx-wrapper.sh"
PATCH_FILES=(
  "$REPO_DIR/patches/codex/ios-exec-hook.patch"
  "$REPO_DIR/patches/codex/client-controlled-handoff.patch"
  "$REPO_DIR/patches/codex/mobile-code-mode-stub.patch"
  "$REPO_DIR/patches/codex/thread-read-permissions.patch"
)

SYNC_MODE="--preserve-current"
DEVICE_ONLY=0
FAST_DEVICE=0
SIM_ONLY=0
FAST_SIM=0
FORCE_BINDINGS=0
SKIP_BINDINGS=0
CARGO_FEATURES=""
PROFILE="release"
CARGO_PROFILE_FLAG="--release"
IOS_RUST_PROFILE="${IOS_RUST_PROFILE:-release}"

if [ "$IOS_RUST_PROFILE" != "release" ]; then
  PROFILE="$IOS_RUST_PROFILE"
  CARGO_PROFILE_FLAG="--profile $IOS_RUST_PROFILE"
fi

for arg in "$@"; do
  case "$arg" in
    --preserve-current|--recorded-gitlink)
      SYNC_MODE="$arg"
      ;;
    --device-only)
      DEVICE_ONLY=1
      ;;
    --fast-device)
      FAST_DEVICE=1
      DEVICE_ONLY=1
      PROFILE="debug"
      CARGO_PROFILE_FLAG=""
      ;;
    --fast-sim)
      FAST_SIM=1
      SIM_ONLY=1
      PROFILE="debug"
      CARGO_PROFILE_FLAG=""
      ;;
    --force-bindings)
      FORCE_BINDINGS=1
      ;;
    --skip-bindings)
      SKIP_BINDINGS=1
      ;;
    --rpc-trace)
      CARGO_FEATURES="--features rpc-trace"
      ;;
    *)
      echo "usage: $(basename "$0") [--preserve-current|--recorded-gitlink] [--device-only] [--fast-device] [--fast-sim] [--force-bindings] [--skip-bindings] [--rpc-trace]" >&2
      exit 1
      ;;
  esac
done

PATCHES_WERE_APPLIED=()
for PATCH_FILE in "${PATCH_FILES[@]}"; do
  if git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
    PATCHES_WERE_APPLIED+=("$PATCH_FILE")
  fi
done

cleanup_patch() {
  for PATCH_FILE in "${PATCH_FILES[@]}"; do
    local was_pre_applied=0
    for pre in "${PATCHES_WERE_APPLIED[@]+"${PATCHES_WERE_APPLIED[@]}"}"; do
      if [ "$pre" = "$PATCH_FILE" ]; then
        was_pre_applied=1
        break
      fi
    done
    if [ "$was_pre_applied" -eq 0 ] && git -C "$SUBMODULE_DIR" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
      echo "==> Reverting $(basename "$PATCH_FILE")..."
      git -C "$SUBMODULE_DIR" apply --reverse "$PATCH_FILE"
    fi
  done
}

trap cleanup_patch EXIT

mkdir -p "$FRAMEWORKS_DIR" "$GENERATED_HEADERS_DIR" "$GENERATED_DEVICE_DIR" "$GENERATED_SIM_DIR"

if [ -z "${RUSTC_WRAPPER:-}" ] && command -v sccache >/dev/null 2>&1; then
  export RUSTC_WRAPPER="$(command -v sccache)"
fi

export CXX_aarch64_apple_ios="$IOS_CLANGXX_WRAPPER"
export CXX_aarch64_apple_ios_sim="$IOS_CLANGXX_WRAPPER"
export IPHONEOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET"

ios_sdk_path() {
  xcrun --sdk "$1" --show-sdk-path
}

IOS_DEVICE_SDK_PATH="$(ios_sdk_path iphoneos)"
IOS_SIM_SDK_PATH="$(ios_sdk_path iphonesimulator)"

# bindgen does not inherit the Meson/cc target sysroot flags above. Without
# target-specific clang args it can pick Homebrew LLVM libc++ headers while
# parsing iOS C++ headers, which produces bogus stdlib/math errors.
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios="${BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios:-"--target=arm64-apple-ios -isysroot $IOS_DEVICE_SDK_PATH -miphoneos-version-min=$IOS_DEPLOYMENT_TARGET -stdlib=libc++"}"
export BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim="${BINDGEN_EXTRA_CLANG_ARGS_aarch64_apple_ios_sim:-"--target=arm64-apple-ios-simulator -isysroot $IOS_SIM_SDK_PATH -mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET -stdlib=libc++"}"
export BINDGEN_EXTRA_CLANG_ARGS_x86_64_apple_ios="${BINDGEN_EXTRA_CLANG_ARGS_x86_64_apple_ios:-"--target=x86_64-apple-ios-simulator -isysroot $IOS_SIM_SDK_PATH -mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET -stdlib=libc++"}"

bindings_inputs() {
  cat <<EOF
$RUST_BRIDGE_DIR/codex-mobile-client/src/lib.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/conversation_uniffi.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/discovery_uniffi.rs
$RUST_BRIDGE_DIR/codex-mobile-client/src/uniffi_shared.rs
$RUST_BRIDGE_DIR/codex-mobile-client/Cargo.toml
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/common.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/v1.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/v2.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/account.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/config_types.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/models.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/openai_models.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/parse_command.rs
$RUST_BRIDGE_DIR/../third_party/codex/codex-rs/protocol/src/protocol.rs
EOF
  find "$RUST_BRIDGE_DIR/codex-mobile-client/src" -type f -name '*.rs' | sort
}

compute_bindings_hash() {
  local file
  {
    while IFS= read -r file; do
      [ -f "$file" ] || continue
      shasum -a 256 "$file"
    done < <(bindings_inputs | sort)
  } | shasum -a 256 | awk '{print $1}'
}

sync_generated_headers() {
  cp "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.h" "$GENERATED_HEADERS_DIR/codex_mobile_clientFFI.h"
  cp "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.modulemap" "$GENERATED_HEADERS_DIR/codex_mobile_clientFFI.modulemap"
  cp "$GENERATED_SWIFT_DIR/module.modulemap" "$GENERATED_HEADERS_DIR/module.modulemap"
}

maybe_generate_swift_bindings() {
  local current_hash existing_hash
  if [ "$SKIP_BINDINGS" -eq 1 ]; then
    echo "==> Skipping UniFFI Swift bindings (--skip-bindings)"
    return
  fi

  current_hash="$(compute_bindings_hash)"
  existing_hash=""
  if [ -f "$BINDINGS_HASH_FILE" ]; then
    existing_hash="$(cat "$BINDINGS_HASH_FILE")"
  fi

  if [ "$FORCE_BINDINGS" -eq 0 ] &&
    [ "$current_hash" = "$existing_hash" ] &&
    [ -f "$GENERATED_SWIFT_DIR/codex_mobile_client.swift" ] &&
    [ -f "$GENERATED_SWIFT_DIR/codex_mobile_clientFFI.h" ] &&
    [ -f "$UNIFFI_OUT" ]; then
    echo "==> Swift bindings unchanged; reusing generated output"
    sync_generated_headers
    return
  fi

  echo "==> Regenerating UniFFI Swift bindings -> $UNIFFI_OUT"
  cd "$RUST_BRIDGE_DIR"
  "$RUST_BRIDGE_DIR/generate-bindings.sh" --swift-only
  cp "$GENERATED_SWIFT_DIR/codex_mobile_client.swift" "$UNIFFI_OUT"
  sync_generated_headers
  printf '%s\n' "$current_hash" >"$BINDINGS_HASH_FILE"
}

copy_device_artifact() {
  cp "$RUST_BRIDGE_DIR/target/aarch64-apple-ios/$PROFILE/libcodex_mobile_client.a" \
    "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
}

copy_sim_artifact() {
  local sim_lib="$1"
  cp "$sim_lib" "$GENERATED_SIM_DIR/libcodex_mobile_client.a"
}

echo "==> Preparing codex submodule..."
"$SCRIPT_DIR/sync-codex.sh" "$SYNC_MODE"

maybe_generate_swift_bindings

echo "==> Installing iOS targets..."
if [ "$DEVICE_ONLY" -eq 1 ]; then
  rustup target add aarch64-apple-ios
elif [ "$SIM_ONLY" -eq 1 ]; then
  rustup target add aarch64-apple-ios-sim
else
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim
fi

if [ "$DEVICE_ONLY" -eq 1 ]; then
  echo "==> Building codex-mobile-client for aarch64-apple-ios ($PROFILE)..."
  cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios --crate-type staticlib $CARGO_FEATURES
  copy_device_artifact
elif [ "$SIM_ONLY" -eq 1 ]; then
  echo "==> Building codex-mobile-client for aarch64-apple-ios-sim ($PROFILE)..."
  cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-sim --crate-type staticlib $CARGO_FEATURES
  copy_sim_artifact "$RUST_BRIDGE_DIR/target/aarch64-apple-ios-sim/$PROFILE/libcodex_mobile_client.a"
else
  # Build device and simulator targets in parallel
  echo "==> Building codex-mobile-client for aarch64-apple-ios + aarch64-apple-ios-sim ($PROFILE) in parallel..."

  build_device() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios --crate-type staticlib $CARGO_FEATURES
  }

  build_sim() {
    cargo rustc --manifest-path "$RUST_BRIDGE_DIR/Cargo.toml" -p codex-mobile-client $CARGO_PROFILE_FLAG --target aarch64-apple-ios-sim --crate-type staticlib $CARGO_FEATURES
  }

  build_device &
  DEVICE_PID=$!
  build_sim &
  SIM_PID=$!

  FAILED=0
  if ! wait "$DEVICE_PID"; then
    echo "ERROR: device build (aarch64-apple-ios) failed" >&2
    FAILED=1
  fi
  if ! wait "$SIM_PID"; then
    echo "ERROR: simulator build (aarch64-apple-ios-sim) failed" >&2
    FAILED=1
  fi
  [ "$FAILED" -eq 0 ] || exit 1

  copy_device_artifact
  copy_sim_artifact "$RUST_BRIDGE_DIR/target/aarch64-apple-ios-sim/$PROFILE/libcodex_mobile_client.a"
fi

if [ "$FAST_DEVICE" -eq 1 ]; then
  echo "==> Fast device build complete"
  echo "==> Device staticlib: $GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
  echo "==> Headers: $GENERATED_HEADERS_DIR"
  echo "==> Swift bindings: $UNIFFI_OUT"
  exit 0
fi

if [ "$FAST_SIM" -eq 1 ]; then
  echo "==> Fast simulator build complete"
  echo "==> Simulator staticlib: $GENERATED_SIM_DIR/libcodex_mobile_client.a"
  echo "==> Headers: $GENERATED_HEADERS_DIR"
  echo "==> Swift bindings: $UNIFFI_OUT"
  exit 0
fi

echo "==> Creating xcframework..."
rm -rf "$FRAMEWORKS_DIR/codex_bridge.xcframework" "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
if [ "$DEVICE_ONLY" -eq 1 ]; then
  xcodebuild -create-xcframework \
    -library "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
else
  xcodebuild -create-xcframework \
    -library "$GENERATED_DEVICE_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -library "$GENERATED_SIM_DIR/libcodex_mobile_client.a" \
    -headers "$GENERATED_HEADERS_DIR" \
    -output "$FRAMEWORKS_DIR/codex_mobile_client.xcframework"
fi

echo "==> Done: $FRAMEWORKS_DIR/codex_mobile_client.xcframework"
echo "==> Raw device staticlib: $GENERATED_DEVICE_DIR/libcodex_mobile_client.a"
if [ "$DEVICE_ONLY" -eq 0 ]; then
  echo "==> Raw simulator staticlib: $GENERATED_SIM_DIR/libcodex_mobile_client.a"
fi
echo "==> Headers: $GENERATED_HEADERS_DIR"
echo "==> Swift bindings: $UNIFFI_OUT"
