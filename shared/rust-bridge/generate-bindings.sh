#!/usr/bin/env bash
#
# Generate Swift/Kotlin bindings from codex-mobile-client.
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

if [[ -z "${RUSTC_WRAPPER:-}" ]] && command -v sccache >/dev/null 2>&1; then
    export RUSTC_WRAPPER="$(command -v sccache)"
fi

PROFILE="debug"
GENERATE_SWIFT=1
GENERATE_KOTLIN=1
HOST_OS="$(uname)"

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

DYLIB_FILE=""
KOTLIN_LIB_FILE=""

if [[ "$GENERATE_SWIFT" -eq 1 || "$HOST_OS" == "Darwin" ]]; then
    # -----------------------------------------------------------------------
    # Build host cdylib for Swift generation (and optional Kotlin on macOS)
    # -----------------------------------------------------------------------
    echo "==> Building codex-mobile-client host cdylib ($PROFILE)..."
    if [[ "$PROFILE" == "release" ]]; then
        cargo build -p codex-mobile-client --release
    else
        cargo build -p codex-mobile-client
    fi

    DYLIB_PATH="$WORKSPACE_DIR/target/$PROFILE"
    if [[ "$HOST_OS" == "Darwin" ]]; then
        DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.dylib"
    else
        DYLIB_FILE="$DYLIB_PATH/libcodex_mobile_client.so"
    fi

    if [[ ! -f "$DYLIB_FILE" ]]; then
        echo "ERROR: Could not find built host library at $DYLIB_FILE" >&2
        exit 1
    fi
fi

if [[ "$GENERATE_SWIFT" -eq 1 ]]; then
    echo "==> Generating Swift bindings -> $OUT_SWIFT"
    mkdir -p "$OUT_SWIFT"
    rm -f \
        "$OUT_SWIFT/codex_app_server_protocol.swift" \
        "$OUT_SWIFT/codex_app_server_protocolFFI.h" \
        "$OUT_SWIFT/codex_app_server_protocolFFI.modulemap" \
        "$OUT_SWIFT/codex_protocol.swift" \
        "$OUT_SWIFT/codex_protocolFFI.h" \
        "$OUT_SWIFT/codex_protocolFFI.modulemap"
    cargo run -p uniffi-bindgen -- generate \
        --library "$DYLIB_FILE" \
        --language swift \
        --out-dir "$OUT_SWIFT"
    cp "$OUT_SWIFT/codex_mobile_clientFFI.modulemap" "$OUT_SWIFT/module.modulemap"
fi

if [[ "$GENERATE_KOTLIN" -eq 1 ]]; then
    if [[ "$HOST_OS" == "Linux" ]]; then
        # Linux host builds can fail when upstream pulls V8 for code-mode.
        # Prefer an Android .so as UniFFI metadata source for Kotlin bindings.
        if [[ -n "${UNIFFI_KOTLIN_LIBRARY:-}" ]]; then
            KOTLIN_LIB_FILE="$UNIFFI_KOTLIN_LIBRARY"
        else
            DEFAULT_ANDROID_SO="$WORKSPACE_DIR/../../apps/android/core/bridge/src/main/jniLibs/arm64-v8a/libcodex_mobile_client.so"
            if [[ -f "$DEFAULT_ANDROID_SO" ]]; then
                KOTLIN_LIB_FILE="$DEFAULT_ANDROID_SO"
            else
                if ! command -v cargo-ndk >/dev/null 2>&1; then
                    echo "ERROR: cargo-ndk not found and no Android library available for Kotlin bindings" >&2
                    echo "hint: install cargo-ndk or set UNIFFI_KOTLIN_LIBRARY to a built libcodex_mobile_client.so" >&2
                    exit 1
                fi
                if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
                    echo "ERROR: ANDROID_NDK_HOME is required to build Android library for Kotlin bindings" >&2
                    exit 1
                fi
                echo "==> Building Android arm64-v8a cdylib for Kotlin bindings..."
                cargo ndk -t arm64-v8a build -p codex-mobile-client
                KOTLIN_LIB_FILE="$WORKSPACE_DIR/target/aarch64-linux-android/debug/libcodex_mobile_client.so"
            fi
        fi
    else
        KOTLIN_LIB_FILE="$DYLIB_FILE"
    fi

    if [[ -z "$KOTLIN_LIB_FILE" || ! -f "$KOTLIN_LIB_FILE" ]]; then
        echo "ERROR: Could not find Kotlin binding library at $KOTLIN_LIB_FILE" >&2
        exit 1
    fi

    echo "==> Generating Kotlin bindings -> $OUT_KOTLIN"
    mkdir -p "$OUT_KOTLIN"
    rm -rf \
        "$OUT_KOTLIN/uniffi/codex_app_server_protocol" \
        "$OUT_KOTLIN/uniffi/codex_protocol"
    cargo run -p uniffi-bindgen -- generate \
        --library "$KOTLIN_LIB_FILE" \
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
