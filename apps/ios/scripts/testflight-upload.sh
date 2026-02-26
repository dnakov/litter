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
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
BETA_GROUP_NAME="${BETA_GROUP_NAME:-Internal Testers}"
ASSIGN_BETA_GROUP="${ASSIGN_BETA_GROUP:-1}"
WAIT_FOR_PROCESSING="${WAIT_FOR_PROCESSING:-1}"
BUILD_POLL_TIMEOUT_SECONDS="${BUILD_POLL_TIMEOUT_SECONDS:-900}"
BUILD_POLL_INTERVAL_SECONDS="${BUILD_POLL_INTERVAL_SECONDS:-15}"
WHAT_TO_TEST="${WHAT_TO_TEST:-}"
WHAT_TO_TEST_LOCALE="${WHAT_TO_TEST_LOCALE:-en-US}"
WHAT_TO_TEST_FILE="${WHAT_TO_TEST_FILE:-$ROOT_DIR/docs/releases/testflight-whats-new.md}"
AUTO_GENERATE_WHAT_TO_TEST="${AUTO_GENERATE_WHAT_TO_TEST:-1}"
WHAT_TO_TEST_MAX_COMMITS="${WHAT_TO_TEST_MAX_COMMITS:-8}"
AUTO_ASSIGN_ENCRYPTION_DECLARATION="${AUTO_ASSIGN_ENCRYPTION_DECLARATION:-1}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$REPO_DIR/build/testflight}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
IPA_PATH="$BUILD_DIR/$SCHEME.ipa"

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

mkdir -p "$BUILD_DIR"

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

if [[ -z "$TEAM_ID" ]]; then
    TEAM_ID="$(resolve_team_from_profile "$PROVISIONING_PROFILE_SPECIFIER" || true)"
fi

if [[ -z "$APP_STORE_APP_ID" ]]; then
    echo "Unable to resolve App Store Connect app id for bundle id: $APP_BUNDLE_ID" >&2
    exit 1
fi

if [[ -z "$TEAM_ID" ]]; then
    echo "Unable to resolve DEVELOPMENT_TEAM for signing." >&2
    echo "Set TEAM_ID explicitly or ensure provisioning profile '$PROVISIONING_PROFILE_SPECIFIER' is installed." >&2
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

echo "==> Regenerating Xcode project"
xcodegen generate --spec "$REPO_DIR/project.yml" --project "$PROJECT_DIR"

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

if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    archive_cmd+=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

"${archive_cmd[@]}"

cat >"$EXPORT_OPTIONS_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>manual</string>
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
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"

echo "==> Exporting IPA"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$BUILD_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

exported_ipa="$(find "$BUILD_DIR" -maxdepth 1 -name "*.ipa" | head -n 1)"
if [[ -z "$exported_ipa" ]]; then
    echo "No IPA produced in $BUILD_DIR" >&2
    exit 1
fi
if [[ "$exported_ipa" != "$IPA_PATH" ]]; then
    cp "$exported_ipa" "$IPA_PATH"
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

    beta_group_id="$(
        asc testflight beta-groups list --app "$APP_STORE_APP_ID" --output json |
            jq -r --arg name "$BETA_GROUP_NAME" '.data[] | select(.attributes.name == $name) | .id' |
            head -n 1
    )"

    if [[ -z "$beta_group_id" ]]; then
        beta_group_id="$(
            asc testflight beta-groups create --app "$APP_STORE_APP_ID" --name "$BETA_GROUP_NAME" --internal --output json |
                jq -r '.data.id // empty'
        )"
    fi

    if [[ -n "$beta_group_id" ]]; then
        echo "==> Assigning build $build_id to beta group '$BETA_GROUP_NAME'"
        deadline="$(( $(date +%s) + BUILD_POLL_TIMEOUT_SECONDS ))"
        assigned=0
        while [[ "$(date +%s)" -lt "$deadline" ]]; do
            if asc builds add-groups --build "$build_id" --group "$beta_group_id" --output json >/dev/null 2>&1; then
                assigned=1
                break
            fi
            sleep "$BUILD_POLL_INTERVAL_SECONDS"
        done
        if [[ "$assigned" -ne 1 ]]; then
            echo "Failed to assign build $build_id to beta group '$BETA_GROUP_NAME' within timeout." >&2
            exit 1
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
