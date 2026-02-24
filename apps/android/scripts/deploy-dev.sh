#!/usr/bin/env bash
set -e

# Auto-detect Java from Android Studio if JAVA_HOME not set
if [ -z "$JAVA_HOME" ]; then
    AS_JAVA="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    [ -d "$AS_JAVA" ] && export JAVA_HOME="$AS_JAVA"
fi

export PATH="$PATH:$HOME/Library/Android/sdk/platform-tools"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_DIR="$SCRIPT_DIR/.."
APK="$ANDROID_DIR/app/build/outputs/apk/onDevice/debug/app-onDevice-debug.apk"

echo "==> Building onDevice debug APK..."
"$ANDROID_DIR/gradlew" -p "$ANDROID_DIR" :app:assembleOnDeviceDebug

echo "==> Installing to all connected devices..."
DEVICES=$(adb devices | awk '/\tdevice$/{print $1}')

if [ -z "$DEVICES" ]; then
    echo "No devices/emulators found. Connect a device or start an emulator first."
    exit 1
fi

for SERIAL in $DEVICES; do
    echo "  -> Installing on $SERIAL"
    adb -s "$SERIAL" install -r "$APK"
done

echo "==> Done."
