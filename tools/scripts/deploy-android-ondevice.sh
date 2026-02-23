#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

APP_ID="com.sigkitten.litter.android"
MAIN_ACTIVITY="com.litter.android.MainActivity"
APK_PATH="$REPO_DIR/apps/android/app/build/outputs/apk/onDevice/debug/app-onDevice-debug.apk"

SERIAL="${ANDROID_SERIAL:-}"
SKIP_RUST=0
SKIP_LAUNCH=0

usage() {
  cat <<'EOF'
Usage: ./tools/scripts/deploy-android-ondevice.sh [options]

Builds Android Rust bridge libs, assembles onDevice debug APK, installs to a device,
and launches the app.

Options:
  -s, --serial <device-serial>  ADB serial to target (or set ANDROID_SERIAL)
      --skip-rust               Skip Rust bridge rebuild
      --no-launch               Install only (do not launch app)
  -h, --help                    Show this help
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    -s|--serial)
      SERIAL="${2:-}"
      if [ -z "$SERIAL" ]; then
        echo "error: --serial requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --skip-rust)
      SKIP_RUST=1
      shift
      ;;
    --no-launch)
      SKIP_LAUNCH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

resolve_serial() {
  if [ -n "$SERIAL" ]; then
    return
  fi

  local count=0
  local candidate=""
  while IFS= read -r line; do
    candidate="$line"
    count=$((count + 1))
  done <<EOF
$(adb devices | awk 'NR>1 && $2=="device" { print $1 }')
EOF

  if [ "$count" -eq 0 ]; then
    echo "error: no connected adb devices found" >&2
    exit 1
  fi

  if [ "$count" -gt 1 ]; then
    echo "error: multiple adb devices found; pass --serial or set ANDROID_SERIAL" >&2
    adb devices -l
    exit 1
  fi

  SERIAL="$candidate"
}

detect_ndk() {
  if [ -n "${ANDROID_NDK_HOME:-}" ] && [ -d "$ANDROID_NDK_HOME" ]; then
    echo "$ANDROID_NDK_HOME"
    return
  fi

  if [ -n "${ANDROID_NDK_ROOT:-}" ] && [ -d "$ANDROID_NDK_ROOT" ]; then
    echo "$ANDROID_NDK_ROOT"
    return
  fi

  local sdk
  for sdk in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [ -n "$sdk" ] || continue
    [ -d "$sdk/ndk" ] || continue

    local latest=""
    latest="$(ls -1 "$sdk/ndk" 2>/dev/null | sort -V | tail -n1 || true)"
    if [ -n "$latest" ] && [ -d "$sdk/ndk/$latest" ]; then
      echo "$sdk/ndk/$latest"
      return
    fi
  done

  echo ""
}

require_cmd adb
require_cmd gradle

resolve_serial

if [ "$SKIP_RUST" -eq 0 ]; then
  NDK_PATH="$(detect_ndk)"
  if [ -z "$NDK_PATH" ]; then
    echo "error: could not find Android NDK; set ANDROID_NDK_HOME or ANDROID_NDK_ROOT" >&2
    exit 1
  fi

  export ANDROID_NDK_HOME="$NDK_PATH"
  export ANDROID_NDK_ROOT="$NDK_PATH"

  echo "==> Using Android NDK: $NDK_PATH"
  "$REPO_DIR/tools/scripts/build-android-rust.sh"
fi

echo "==> Assembling onDevice debug APK..."
gradle -p "$REPO_DIR/apps/android" :app:assembleOnDeviceDebug

if [ ! -f "$APK_PATH" ]; then
  echo "error: APK not found at $APK_PATH" >&2
  exit 1
fi

echo "==> Installing APK to $SERIAL..."
adb -s "$SERIAL" install -r "$APK_PATH"

if [ "$SKIP_LAUNCH" -eq 0 ]; then
  echo "==> Launching app on $SERIAL..."
  adb -s "$SERIAL" shell am start -n "$APP_ID/$MAIN_ACTIVITY"
fi

echo "==> Done."
