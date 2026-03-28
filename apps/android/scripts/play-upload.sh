#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANDROID_DIR="$REPO_DIR/apps/android"
GRADLEW="$ANDROID_DIR/gradlew"

VARIANT="${VARIANT:-Release}"
UPLOAD="${UPLOAD:-1}"
TRACK="${LITTER_PLAY_TRACK:-internal}"
GRADLE_MAX_WORKERS="${GRADLE_MAX_WORKERS:-}"
EXTRA_GRADLE_TASKS="${EXTRA_GRADLE_TASKS:-}"
GRADLE_EXCLUDED_TASKS="${GRADLE_EXCLUDED_TASKS:-}"

declare -a GRADLE_ARGS=(--no-daemon)
if [[ -n "$GRADLE_MAX_WORKERS" ]]; then
    GRADLE_ARGS+=("--max-workers=$GRADLE_MAX_WORKERS")
fi
if [[ -n "$GRADLE_EXCLUDED_TASKS" ]]; then
    EXCLUDED_TASKS_NORMALIZED="${GRADLE_EXCLUDED_TASKS//,/ }"
    read -r -a EXCLUDED_TASKS <<<"$EXCLUDED_TASKS_NORMALIZED"
    for task in "${EXCLUDED_TASKS[@]}"; do
        [[ -n "$task" ]] || continue
        GRADLE_ARGS+=("-x" "$task")
    done
fi

# Source credentials from env file if present and vars are not already set
ENV_FILE="${HOME}/.config/litter/play-upload.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
fi

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "Missing required env var: $name" >&2
        echo "Hint: create $ENV_FILE with exports, or set vars directly." >&2
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
    GRADLE_TASKS=()
    if [[ -n "$EXTRA_GRADLE_TASKS" ]]; then
        EXTRA_TASKS_NORMALIZED="${EXTRA_GRADLE_TASKS//,/ }"
        read -r -a EXTRA_TASKS <<<"$EXTRA_TASKS_NORMALIZED"
        GRADLE_TASKS+=("${EXTRA_TASKS[@]}")
    fi
    GRADLE_TASKS+=("$TASK")
    "$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "${GRADLE_TASKS[@]}" \
        -PLITTER_PLAY_SERVICE_ACCOUNT_JSON="$LITTER_PLAY_SERVICE_ACCOUNT_JSON" \
        -PLITTER_PLAY_TRACK="$TRACK" \
        -PLITTER_UPLOAD_STORE_FILE="$LITTER_UPLOAD_STORE_FILE" \
        -PLITTER_UPLOAD_STORE_PASSWORD="$LITTER_UPLOAD_STORE_PASSWORD" \
        -PLITTER_UPLOAD_KEY_ALIAS="$LITTER_UPLOAD_KEY_ALIAS" \
        -PLITTER_UPLOAD_KEY_PASSWORD="$LITTER_UPLOAD_KEY_PASSWORD"
else
    TASK=":app:bundle${VARIANT}"
    echo "==> Building local AAB for $VARIANT (no upload)"
    GRADLE_TASKS=()
    if [[ -n "$EXTRA_GRADLE_TASKS" ]]; then
        EXTRA_TASKS_NORMALIZED="${EXTRA_GRADLE_TASKS//,/ }"
        read -r -a EXTRA_TASKS <<<"$EXTRA_TASKS_NORMALIZED"
        GRADLE_TASKS+=("${EXTRA_TASKS[@]}")
    fi
    GRADLE_TASKS+=("$TASK")
    "$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "${GRADLE_TASKS[@]}"
fi

echo "==> Done"
