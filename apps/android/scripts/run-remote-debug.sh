#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANDROID_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_ID="com.sigkitten.litter.android"
ACTIVITY="com.litter.android.MainActivity"
PORT="${OPENCODE_PORT:-4096}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not installed or not on PATH" >&2
  exit 1
fi

adb start-server >/dev/null

DEVICE_LINE="$(adb devices | awk 'NR>1 && $2 != "" {print $0; exit}')"
if [[ -z "$DEVICE_LINE" ]]; then
  echo "No Android device detected over adb" >&2
  exit 1
fi

DEVICE_STATE="$(printf '%s\n' "$DEVICE_LINE" | awk '{print $2}')"
if [[ "$DEVICE_STATE" == "unauthorized" ]]; then
  echo "Android device is connected but unauthorized." >&2
  echo "Unlock the phone, accept the USB debugging prompt, then rerun this command." >&2
  exit 1
fi

if [[ "$DEVICE_STATE" != "device" ]]; then
  echo "Android device is not ready: $DEVICE_STATE" >&2
  exit 1
fi

"$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" :app:installRemoteOnlyDebug
adb reverse "tcp:${PORT}" "tcp:${PORT}"
adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
adb shell am start -n "${APP_ID}/${ACTIVITY}" >/dev/null

echo "Installed and launched ${APP_ID}."
echo "OpenCode endpoint for the app: 127.0.0.1:${PORT}"
