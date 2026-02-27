#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANDROID_DIR="$REPO_DIR/apps/android"

VARIANT="${VARIANT:-OnDeviceRelease}"
UPLOAD="${UPLOAD:-1}"
TRACK="${LITTER_PLAY_TRACK:-internal}"

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required env var: $name" >&2
        exit 1
    fi
}

if [[ "$UPLOAD" == "1" ]]; then
    require_env "LITTER_PLAY_SERVICE_ACCOUNT_JSON"
    require_env "LITTER_UPLOAD_STORE_FILE"
    require_env "LITTER_UPLOAD_STORE_PASSWORD"
    require_env "LITTER_UPLOAD_KEY_ALIAS"
    require_env "LITTER_UPLOAD_KEY_PASSWORD"

    if [[ ! -f "$LITTER_PLAY_SERVICE_ACCOUNT_JSON" ]]; then
        echo "Service account JSON not found: $LITTER_PLAY_SERVICE_ACCOUNT_JSON" >&2
        exit 1
    fi
    if [[ ! -f "$LITTER_UPLOAD_STORE_FILE" ]]; then
        echo "Upload keystore not found: $LITTER_UPLOAD_STORE_FILE" >&2
        exit 1
    fi

    TASK=":app:publish${VARIANT}Bundle"
    echo "==> Publishing $VARIANT bundle to Google Play track '$TRACK'"
    gradle -p "$ANDROID_DIR" "$TASK" \
        -PLITTER_PLAY_SERVICE_ACCOUNT_JSON="$LITTER_PLAY_SERVICE_ACCOUNT_JSON" \
        -PLITTER_PLAY_TRACK="$TRACK" \
        -PLITTER_UPLOAD_STORE_FILE="$LITTER_UPLOAD_STORE_FILE" \
        -PLITTER_UPLOAD_STORE_PASSWORD="$LITTER_UPLOAD_STORE_PASSWORD" \
        -PLITTER_UPLOAD_KEY_ALIAS="$LITTER_UPLOAD_KEY_ALIAS" \
        -PLITTER_UPLOAD_KEY_PASSWORD="$LITTER_UPLOAD_KEY_PASSWORD"
else
    TASK=":app:bundle${VARIANT}"
    echo "==> Building local AAB for $VARIANT (no upload)"
    gradle -p "$ANDROID_DIR" "$TASK"
fi

echo "==> Done"
