#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ANDROID_DIR="$REPO_DIR/apps/android"
GRADLEW="$ANDROID_DIR/gradlew"

VARIANT="${VARIANT:-Release}"
UPLOAD="${UPLOAD:-1}"
TRACK="${LITTER_PLAY_TRACK:-internal}"
PROMOTE_TRACK="${LITTER_PLAY_PROMOTE_TRACK:-}"
# Release status applied to the *final* landing track (promote dest when
# promoting, else the upload track). The initial upload to the source track
# always goes out at 100% COMPLETED so internal testers see it immediately.
RELEASE_STATUS="${LITTER_PLAY_RELEASE_STATUS:-}"
USER_FRACTION="${LITTER_PLAY_USER_FRACTION:-}"
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

# Shared signing + service-account props used by every Gradle invocation.
declare -a BASE_PROPS=(
    -PLITTER_PLAY_SERVICE_ACCOUNT_JSON="${LITTER_PLAY_SERVICE_ACCOUNT_JSON:-}"
    -PLITTER_PLAY_TRACK="$TRACK"
    -PLITTER_UPLOAD_STORE_FILE="${LITTER_UPLOAD_STORE_FILE:-}"
    -PLITTER_UPLOAD_STORE_PASSWORD="${LITTER_UPLOAD_STORE_PASSWORD:-}"
    -PLITTER_UPLOAD_KEY_ALIAS="${LITTER_UPLOAD_KEY_ALIAS:-}"
    -PLITTER_UPLOAD_KEY_PASSWORD="${LITTER_UPLOAD_KEY_PASSWORD:-}"
)
if [[ -n "$PROMOTE_TRACK" ]]; then
    BASE_PROPS+=(-PLITTER_PLAY_PROMOTE_TRACK="$PROMOTE_TRACK")
fi

# ── Local build only ───────────────────────────────────────────────────────
if [[ "$UPLOAD" != "1" ]]; then
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
    echo "==> Done"
    exit 0
fi

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

# ── Step 1: publish to the source track at 100% COMPLETED ───────────────────
# We always want the source track (e.g. internal) to have a fully-rolled-out
# release so internal testers and the promotion step both see the build.
PUBLISH_TASK=":app:publish${VARIANT}Bundle"
echo "==> Publishing $VARIANT bundle to Google Play track '$TRACK' (100% rollout)"

declare -a PUBLISH_TASKS=()
if [[ -n "$EXTRA_GRADLE_TASKS" ]]; then
    EXTRA_TASKS_NORMALIZED="${EXTRA_GRADLE_TASKS//,/ }"
    read -r -a EXTRA_TASKS <<<"$EXTRA_TASKS_NORMALIZED"
    PUBLISH_TASKS+=("${EXTRA_TASKS[@]}")
fi
PUBLISH_TASKS+=("$PUBLISH_TASK")

"$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "${PUBLISH_TASKS[@]}" "${BASE_PROPS[@]}" \
    -PLITTER_PLAY_RELEASE_STATUS=completed

# ── Step 2: optionally promote to another track ─────────────────────────────
if [[ -n "$PROMOTE_TRACK" ]]; then
    PROMOTE_TASK=":app:promote${VARIANT}Artifact"
    status_for_promote="${RELEASE_STATUS:-completed}"
    declare -a PROMOTE_PROPS=(-PLITTER_PLAY_RELEASE_STATUS="$status_for_promote")
    if [[ -n "$USER_FRACTION" ]]; then
        PROMOTE_PROPS+=(-PLITTER_PLAY_USER_FRACTION="$USER_FRACTION")
    fi
    rollout_info=""
    if [[ "$status_for_promote" == "inProgress" || "$status_for_promote" == "in_progress" ]]; then
        rollout_info=" (staged at userFraction=${USER_FRACTION:-not set})"
    fi
    echo "==> Promoting '$TRACK' → '$PROMOTE_TRACK' [status=$status_for_promote]${rollout_info}"
    "$GRADLEW" -p "$ANDROID_DIR" "${GRADLE_ARGS[@]}" "$PROMOTE_TASK" "${BASE_PROPS[@]}" "${PROMOTE_PROPS[@]}"
fi

echo "==> Done"
