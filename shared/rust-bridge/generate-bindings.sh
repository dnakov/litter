#!/usr/bin/env bash
#
# Generate protocol wrappers plus Swift/Kotlin bindings from codex-mobile-client.
#
# Usage:  ./generate-bindings.sh [--release] [--swift-only] [--kotlin-only]
#
# Outputs:
#   generated/swift/   — Swift source files
#   generated/kotlin/  — Kotlin source files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$SCRIPT_DIR"
CRATE_DIR="$WORKSPACE_DIR/codex-mobile-client"
OUT_SWIFT="$WORKSPACE_DIR/generated/swift"
OUT_KOTLIN="$WORKSPACE_DIR/generated/kotlin"

cd "$WORKSPACE_DIR"

PROFILE="debug"
GENERATE_SWIFT=1
GENERATE_KOTLIN=1

for arg in "$@"; do
    case "$arg" in
        --release)
            PROFILE="release"
            ;;
        --swift-only)
            GENERATE_KOTLIN=0
            ;;
        --kotlin-only)
            GENERATE_SWIFT=0
            ;;
        *)
            echo "usage: $(basename "$0") [--release] [--swift-only] [--kotlin-only]" >&2
            exit 1
            ;;
    esac
done

if [[ "$GENERATE_SWIFT" -eq 0 && "$GENERATE_KOTLIN" -eq 0 ]]; then
    echo "error: nothing to generate" >&2
    exit 1
fi

UPSTREAM_V2="$WORKSPACE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/v2.rs"
UPSTREAM_COMMON="$WORKSPACE_DIR/../third_party/codex/codex-rs/app-server-protocol/src/protocol/common.rs"
TYPES_OUT="$CRATE_DIR/src/types/codegen_types.generated.rs"
RPC_OUT="$CRATE_DIR/src/rpc/generated_client.rs"
FFI_RPC_OUT="$CRATE_DIR/src/ffi/rpc.rs"

echo "==> Regenerating protocol wrappers..."
cargo run -p codex-mobile-codegen -- \
    --upstream "$UPSTREAM_V2" \
    --common "$UPSTREAM_COMMON" \
    --out "$TYPES_OUT" \
    --rpc-out "$RPC_OUT" \
    --ffi-rpc-out "$FFI_RPC_OUT"

# ---------------------------------------------------------------------------
# 1. Build the cdylib so uniffi-bindgen can read its metadata
# ---------------------------------------------------------------------------
# Temporarily add cdylib crate-type for uniffi-bindgen (needs a dylib to read metadata).
# The Cargo.toml normally has only ["lib"] to avoid iOS cross-compilation issues.
echo "==> Building codex-mobile-client cdylib ($PROFILE)..."
CARGO_TOML="$CRATE_DIR/Cargo.toml"
sed -i '' 's/crate-type = \["lib"\]/crate-type = ["lib", "cdylib"]/' "$CARGO_TOML"
trap 'sed -i "" "s/crate-type = \[\"lib\", \"cdylib\"\]/crate-type = [\"lib\"]/" "$CARGO_TOML"' EXIT

if [[ "$PROFILE" == "release" ]]; then
    cargo build -p codex-mobile-client --release
else
    cargo build -p codex-mobile-client
fi

DYLIB_PATH="$WORKSPACE_DIR/target/$PROFILE"

# Resolve the dynamic library name per platform
if [[ "$(uname)" == "Darwin" ]]; then
    DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.dylib"
else
    DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.so"
fi

if [[ ! -f "$DYLIB_FILE" ]]; then
    echo "ERROR: Could not find built library at $DYLIB_FILE" >&2
    exit 1
fi

if [[ "$GENERATE_SWIFT" -eq 1 ]]; then
    echo "==> Generating Swift bindings -> $OUT_SWIFT"
    mkdir -p "$OUT_SWIFT"
    cargo run -p uniffi-bindgen -- generate \
        --library "$DYLIB_FILE" \
        --language swift \
        --out-dir "$OUT_SWIFT"
    cp "$OUT_SWIFT/codex_mobile_clientFFI.modulemap" "$OUT_SWIFT/module.modulemap"
fi

if [[ "$GENERATE_KOTLIN" -eq 1 ]]; then
    echo "==> Generating Kotlin bindings -> $OUT_KOTLIN"
    mkdir -p "$OUT_KOTLIN"
    cargo run -p uniffi-bindgen -- generate \
        --library "$DYLIB_FILE" \
        --language kotlin \
        --out-dir "$OUT_KOTLIN"
fi

echo "==> Done. Generated bindings:"
if [[ "$GENERATE_SWIFT" -eq 1 && "$GENERATE_KOTLIN" -eq 1 ]]; then
    find "$OUT_SWIFT" "$OUT_KOTLIN" -type f | sort
elif [[ "$GENERATE_SWIFT" -eq 1 ]]; then
    find "$OUT_SWIFT" -type f | sort
else
    find "$OUT_KOTLIN" -type f | sort
fi
