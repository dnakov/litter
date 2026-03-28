#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$REPO_DIR/../.." && pwd)"

SCHEME="${SCHEME:-Litter}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_DIR="${PROJECT_DIR:-$REPO_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
TEAM_ID="${TEAM_ID:-}"
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-Litter App Store}"
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-automatic}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
ASSIGN_BETA_GROUP="${ASSIGN_BETA_GROUP:-1}"
INTERNAL_BETA_GROUP_NAME="${INTERNAL_BETA_GROUP_NAME:-Internal Testers}"
EXTERNAL_BETA_GROUP_NAME="${EXTERNAL_BETA_GROUP_NAME:-External Testers}"
LEGACY_BETA_GROUP_NAME="${BETA_GROUP_NAME:-}"
if [[ -n "${BETA_GROUP_NAMES:-}" ]]; then
    BETA_GROUP_NAMES="${BETA_GROUP_NAMES}"
elif [[ -n "$LEGACY_BETA_GROUP_NAME" ]]; then
    BETA_GROUP_NAMES="$LEGACY_BETA_GROUP_NAME"
else
    BETA_GROUP_NAMES="$INTERNAL_BETA_GROUP_NAME,$EXTERNAL_BETA_GROUP_NAME"
fi
SUBMIT_BETA_REVIEW="${SUBMIT_BETA_REVIEW:-1}"
WAIT_FOR_PROCESSING="${WAIT_FOR_PROCESSING:-1}"
BUILD_POLL_TIMEOUT_SECONDS="${BUILD_POLL_TIMEOUT_SECONDS:-900}"
BUILD_POLL_INTERVAL_SECONDS="${BUILD_POLL_INTERVAL_SECONDS:-15}"
WHAT_TO_TEST="${WHAT_TO_TEST:-}"
WHAT_TO_TEST_LOCALE="${WHAT_TO_TEST_LOCALE:-en-US}"
WHAT_TO_TEST_FILE="${WHAT_TO_TEST_FILE:-$ROOT_DIR/docs/releases/testflight-whats-new.md}"
AUTO_GENERATE_WHAT_TO_TEST="${AUTO_GENERATE_WHAT_TO_TEST:-1}"
WHAT_TO_TEST_MAX_COMMITS="${WHAT_TO_TEST_MAX_COMMITS:-8}"
AUTO_ASSIGN_ENCRYPTION_DECLARATION="${AUTO_ASSIGN_ENCRYPTION_DECLARATION:-1}"
TESTFLIGHT_SKIP_BUILD="${TESTFLIGHT_SKIP_BUILD:-0}"
TESTFLIGHT_SKIP_UPLOAD="${TESTFLIGHT_SKIP_UPLOAD:-0}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build/testflight}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
IPA_PATH="$BUILD_DIR/$SCHEME.ipa"
BUILD_METADATA_PATH="${BUILD_METADATA_PATH:-$BUILD_DIR/testflight-build.env}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_cmd asc
require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen

if [[ -x "$SCRIPT_DIR/sanitize-ios-frameworks.sh" ]]; then
    "$SCRIPT_DIR/sanitize-ios-frameworks.sh"
fi

mkdir -p "$BUILD_DIR"

if [[ -f "$BUILD_METADATA_PATH" ]]; then
    # shellcheck disable=SC1090
    source "$BUILD_METADATA_PATH"
fi

if [[ "$MARKETING_VERSION" != "1.0.1" ]]; then
    echo "TestFlight uploads must use MARKETING_VERSION=1.0.1 (got $MARKETING_VERSION)" >&2
    exit 1
fi

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

resolve_team_from_profile() {
    local profile_name="$1"
    local profile_dir="$HOME/Library/MobileDevice/Provisioning Profiles"
    local profile_path profile_display team_id

    [[ -d "$profile_dir" ]] || return 1
    for profile_path in "$profile_dir"/*.mobileprovision; do
        [[ -e "$profile_path" ]] || continue
        profile_display="$(
            security cms -D -i "$profile_path" 2>/dev/null |
                plutil -extract Name raw - 2>/dev/null || true
        )"
        [[ "$profile_display" == "$profile_name" ]] || continue
        team_id="$(
            security cms -D -i "$profile_path" 2>/dev/null |
                plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true
        )"
        if [[ -n "$team_id" ]]; then
            echo "$team_id"
            return 0
        fi
    done
    return 1
}

if [[ -z "$APP_STORE_APP_ID" ]]; then
    APP_STORE_APP_ID="$(
        asc apps list --bundle-id "$APP_BUNDLE_ID" --output json |
            jq -r '.data[0].id // empty'
    )"
fi

if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(
        xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings |
            awk -F' = ' '/ DEVELOPMENT_TEAM = / {print $2; exit}'
    )"
fi

if [[ -z "$TEAM_ID" && "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    TEAM_ID="$(resolve_team_from_profile "$PROVISIONING_PROFILE_SPECIFIER" || true)"
fi

if [[ -z "$APP_STORE_APP_ID" ]]; then
    echo "Unable to resolve App Store Connect app id for bundle id: $APP_BUNDLE_ID" >&2
    exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
    echo "Unable to resolve DEVELOPMENT_TEAM for signing." >&2
    echo "Set TEAM_ID explicitly or ensure the project build settings or provisioning profile can resolve it." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" != "automatic" && "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
    echo "Unsupported EXPORT_SIGNING_STYLE: $EXPORT_SIGNING_STYLE" >&2
    echo "Expected 'automatic' or 'manual'." >&2
    exit 1
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -z "$PROVISIONING_PROFILE_SPECIFIER" ]]; then
    echo "Manual export signing requires PROVISIONING_PROFILE_SPECIFIER." >&2
    exit 1
fi

if [[ -z "$BUILD_NUMBER" ]]; then
    latest_build="$(
        asc builds list --app "$APP_STORE_APP_ID" --limit 1 --sort "-uploadedDate" --output json |
            jq -r '.data[0].attributes.version // empty'
    )"
    if [[ "$latest_build" =~ ^[0-9]+$ ]]; then
        BUILD_NUMBER="$((latest_build + 1))"
    else
        BUILD_NUMBER="$(date +%Y%m%d%H%M)"
    fi
fi

if [[ -z "$WHAT_TO_TEST" && -f "$WHAT_TO_TEST_FILE" ]]; then
    WHAT_TO_TEST="$(cat "$WHAT_TO_TEST_FILE")"
fi

if [[ -z "$WHAT_TO_TEST" && "$AUTO_GENERATE_WHAT_TO_TEST" == "1" ]]; then
    WHAT_TO_TEST="$(
        git -C "$ROOT_DIR" log --no-merges -n "$WHAT_TO_TEST_MAX_COMMITS" --pretty='- %s' |
            sed '/^[[:space:]]*$/d'
    )"
fi

if [[ -z "$WHAT_TO_TEST" ]]; then
    echo "Missing TestFlight changelog (What to Test)." >&2
    echo "Set WHAT_TO_TEST, or populate $WHAT_TO_TEST_FILE." >&2
    exit 1
fi

cat >"$BUILD_METADATA_PATH" <<EOF
BUILD_NUMBER=$(printf '%q' "$BUILD_NUMBER")
APP_STORE_APP_ID=$(printf '%q' "$APP_STORE_APP_ID")
TEAM_ID=$(printf '%q' "$TEAM_ID")
PROVISIONING_PROFILE_SPECIFIER=$(printf '%q' "$PROVISIONING_PROFILE_SPECIFIER")
MARKETING_VERSION=$(printf '%q' "$MARKETING_VERSION")
WHAT_TO_TEST_LOCALE=$(printf '%q' "$WHAT_TO_TEST_LOCALE")
EOF

auth_args=()
if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    auth_args=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

if [[ "$TESTFLIGHT_SKIP_BUILD" != "1" ]]; then
    echo "==> Regenerating Xcode project"
    "$PROJECT_DIR/scripts/regenerate-project.sh"

    echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER)"
    archive_cmd=(
        xcodebuild
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -destination "generic/platform=iOS"
        -archivePath "$ARCHIVE_PATH"
        -allowProvisioningUpdates
        clean archive
        MARKETING_VERSION="$MARKETING_VERSION"
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
    )

    if [[ -n "$TEAM_ID" ]]; then
        archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
    fi

    if [[ "${#auth_args[@]}" -gt 0 ]]; then
        archive_cmd+=("${auth_args[@]}")
    fi

    "${archive_cmd[@]}"

    cat >"$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
</dict>
</plist>
EOF

    if [[ -n "$TEAM_ID" ]]; then
        /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
    fi
    if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
        /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
    fi

    echo "==> Exporting IPA (signing: $EXPORT_SIGNING_STYLE)"
    export_cmd=(
        xcodebuild
        -exportArchive
        -archivePath "$ARCHIVE_PATH"
        -exportPath "$BUILD_DIR"
        -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
        -allowProvisioningUpdates
    )

    if [[ "${#auth_args[@]}" -gt 0 ]]; then
        export_cmd+=("${auth_args[@]}")
    fi

    "${export_cmd[@]}"

    exported_ipa="$(find "$BUILD_DIR" -maxdepth 1 -name "*.ipa" | head -n 1)"
    if [[ -z "$exported_ipa" ]]; then
        echo "No IPA produced in $BUILD_DIR" >&2
        exit 1
    fi
    if [[ "$exported_ipa" != "$IPA_PATH" ]]; then
        cp "$exported_ipa" "$IPA_PATH"
    fi
fi

if [[ ! -f "$IPA_PATH" ]]; then
    echo "Expected IPA at $IPA_PATH" >&2
    exit 1
fi

if [[ "$TESTFLIGHT_SKIP_UPLOAD" == "1" ]]; then
    echo "==> TestFlight build prepared"
    echo "    IPA:         $IPA_PATH"
    echo "    Build:       $BUILD_NUMBER"
    exit 0
fi

echo "==> Uploading IPA to App Store Connect (app: $APP_STORE_APP_ID)"
upload_cmd=(
    asc builds upload
    --app "$APP_STORE_APP_ID"
    --ipa "$IPA_PATH"
    --version "$MARKETING_VERSION"
    --build-number "$BUILD_NUMBER"
    --output json
)
if [[ "$WAIT_FOR_PROCESSING" == "1" ]]; then
    upload_cmd+=(--wait)
fi

upload_json="$("${upload_cmd[@]}")"
echo "$upload_json" >"$BUILD_DIR/upload_result.json"

build_id="$(
    echo "$upload_json" |
        jq -r '.data.id // .data[0].id // empty'
)"
if [[ -z "$build_id" ]]; then
    build_id="$(
        asc builds list --app "$APP_STORE_APP_ID" --limit 20 --sort "-uploadedDate" --output json |
            jq -r --arg num "$BUILD_NUMBER" '.data[] | select(.attributes.version == $num) | .id' |
            head -n 1
    )"
fi

if [[ -z "$build_id" && "$ASSIGN_BETA_GROUP" == "1" ]]; then
    deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
    while [[ -z "$build_id" && "$(date +%s)" -lt "$deadline" ]]; do
        sleep "$BUILD_POLL_INTERVAL_SECONDS"
        build_id="$(
            asc builds list --app "$APP_STORE_APP_ID" --limit 50 --sort "-uploadedDate" --output json |
                jq -r --arg num "$BUILD_NUMBER" '.data[] | select(.attributes.version == $num) | .id' |
                head -n 1
        )"
    done
fi

if [[ -n "$build_id" && "$AUTO_ASSIGN_ENCRYPTION_DECLARATION" == "1" ]]; then
    internal_state="$(
        asc builds build-beta-detail get --build "$build_id" --output json |
            jq -r '.data.attributes.internalBuildState // empty'
    )"
    if [[ "$internal_state" == "MISSING_EXPORT_COMPLIANCE" ]]; then
        declaration_id="$(
            asc encryption declarations list --app "$APP_STORE_APP_ID" --output json |
                jq -r '.data | sort_by(.attributes.createdDate // "") | last | .id // empty'
        )"
        if [[ -n "$declaration_id" ]]; then
            echo "==> Assigning build $build_id to encryption declaration $declaration_id"
            asc encryption declarations assign-builds \
                --id "$declaration_id" \
                --build "$build_id" \
                --output json >/dev/null || true
        fi
    fi
fi

if [[ -n "$build_id" && -n "$WHAT_TO_TEST" ]]; then
    echo "==> Ensuring What to Test notes are set for $WHAT_TO_TEST_LOCALE"
    notes_id="$(
        asc builds test-notes list --build "$build_id" --output json |
            jq -r --arg locale "$WHAT_TO_TEST_LOCALE" \
                '.data[] | select((.attributes.locale // .attributes.localeCode // "") == $locale) | .id' |
            head -n 1
    )"

    if [[ -n "$notes_id" ]]; then
        asc builds test-notes update \
            --id "$notes_id" \
            --whats-new "$WHAT_TO_TEST" \
            --output json >/dev/null
    else
        asc builds test-notes create \
            --build "$build_id" \
            --locale "$WHAT_TO_TEST_LOCALE" \
            --whats-new "$WHAT_TO_TEST" \
            --output json >/dev/null
    fi
fi

if [[ "$ASSIGN_BETA_GROUP" == "1" && -n "$build_id" ]]; then
    beta_group_ids=()
    external_group_requested=0

    IFS=',' read -r -a requested_group_names <<<"$BETA_GROUP_NAMES"
    for raw_group_name in "${requested_group_names[@]}"; do
        group_name="$(trim "$raw_group_name")"
        [[ -n "$group_name" ]] || continue

        beta_group_id="$(
            asc testflight beta-groups list --app "$APP_STORE_APP_ID" --output json |
                jq -r --arg name "$group_name" '.data[] | select(.attributes.name == $name) | .id' |
                head -n 1
        )"

        if [[ -z "$beta_group_id" ]]; then
            create_cmd=(
                asc testflight beta-groups create
                --app "$APP_STORE_APP_ID"
                --name "$group_name"
                --output json
            )
            if [[ "$group_name" == "$INTERNAL_BETA_GROUP_NAME" ]]; then
                create_cmd+=(--internal)
            else
                external_group_requested=1
            fi
            beta_group_id="$(
                "${create_cmd[@]}" |
                    jq -r '.data.id // empty'
            )"
        elif [[ "$group_name" != "$INTERNAL_BETA_GROUP_NAME" ]]; then
            external_group_requested=1
        fi

        if [[ -n "$beta_group_id" ]]; then
            beta_group_ids+=("$beta_group_id")
        fi
    done

    if [[ "${#beta_group_ids[@]}" -gt 0 ]]; then
        group_csv="$(IFS=,; printf '%s' "${beta_group_ids[*]}")"
        echo "==> Assigning build $build_id to beta groups: $BETA_GROUP_NAMES"
        deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
        assigned=0
        while [[ "$(date +%s)" -lt "$deadline" ]]; do
            if asc builds add-groups --build "$build_id" --group "$group_csv" --output json >/dev/null 2>&1; then
                assigned=1
                break
            fi
            sleep "$BUILD_POLL_INTERVAL_SECONDS"
        done
        if [[ "$assigned" -ne 1 ]]; then
            echo "Failed to assign build $build_id to beta groups '$BETA_GROUP_NAMES' within timeout." >&2
            exit 1
        fi

        if [[ "$SUBMIT_BETA_REVIEW" == "1" && "$external_group_requested" -eq 1 ]]; then
            echo "==> Submitting build $build_id for Beta App Review"
            asc testflight review submit --build "$build_id" --confirm --output json >/dev/null
        fi
    fi
fi

echo "==> TestFlight upload complete"
echo "    App ID:      $APP_STORE_APP_ID"
echo "    Scheme:      $SCHEME"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    IPA:         $IPA_PATH"
if [[ -n "${build_id:-}" ]]; then
    echo "    Build record: $build_id"
fi
