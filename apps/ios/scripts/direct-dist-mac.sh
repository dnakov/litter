#!/usr/bin/env bash
# Mac Catalyst direct distribution (Developer ID + notarization).
#
# Pipeline:
#   1. Archive `LitterMac` for Mac Catalyst.
#   2. Export with method=developer-id → produces a Developer ID-signed .app.
#   3. Wrap the .app in a .dmg via hdiutil.
#   4. Sign the .dmg with the Developer ID Application cert so Gatekeeper
#      trusts the container itself, not just the inner .app.
#   5. Submit the .dmg to Apple's notary service via `xcrun notarytool`
#      using the same ASC API key the TestFlight flow uses.
#   6. Staple the notarization ticket to the .dmg so it passes Gatekeeper
#      offline after the first run.
#
# Output: `$BUILD_DIR/Litter-<version>-mac.dmg`, ready to host anywhere.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=release-common.sh
source "$SCRIPT_DIR/release-common.sh"

SCHEME="${SCHEME:-LitterMac}"
CONFIGURATION="${CONFIGURATION:-Release}"
PROJECT_DIR="${PROJECT_DIR:-$IOS_DIR}"
PROJECT_PATH="${PROJECT_PATH:-$PROJECT_DIR/Litter.xcodeproj}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_DISPLAY_NAME="${APP_DISPLAY_NAME:-Litter}"
TEAM_ID="${TEAM_ID:-}"
# Developer ID provisioning profile name (NOT the Mac App Store one). Only
# strictly required for capabilities that demand a profile (APNs, iCloud,
# etc.). If empty, automatic signing is used and Xcode fetches / generates
# whatever is needed.
PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER:-}"
APP_PROVISIONING_PROFILE_SPECIFIER="${APP_PROVISIONING_PROFILE_SPECIFIER:-$PROVISIONING_PROFILE_SPECIFIER}"
# Code sign identity for the .app bundle. `Developer ID Application` is the
# exact CN prefix Apple uses; `security find-identity` will confirm it.
APP_CODE_SIGN_IDENTITY="${APP_CODE_SIGN_IDENTITY:-Developer ID Application}"
EXPORT_SIGNING_STYLE="${EXPORT_SIGNING_STYLE:-automatic}"
MARKETING_VERSION="${MARKETING_VERSION:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
NOTARIZATION_TIMEOUT="${NOTARIZATION_TIMEOUT:-30m}"

AUTH_KEY_PATH="${AUTH_KEY_PATH:-${ASC_PRIVATE_KEY_PATH:-}}"
AUTH_KEY_ID="${AUTH_KEY_ID:-${ASC_KEY_ID:-}}"
AUTH_ISSUER_ID="${AUTH_ISSUER_ID:-${ASC_ISSUER_ID:-}}"

BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build/direct-dist-mac}"
ARCHIVE_PATH="$BUILD_DIR/$SCHEME.xcarchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
EXPORT_DIR="$BUILD_DIR/export"

require_cmd jq
require_cmd xcodebuild
require_cmd xcodegen
require_cmd hdiutil

if [[ "$SKIP_NOTARIZATION" != "1" ]]; then
    if [[ -z "$AUTH_KEY_PATH" || -z "$AUTH_KEY_ID" || -z "$AUTH_ISSUER_ID" ]]; then
        echo "Notarization requires AUTH_KEY_PATH / AUTH_KEY_ID / AUTH_ISSUER_ID (or the ASC_* equivalents)." >&2
        echo "Set SKIP_NOTARIZATION=1 to build an un-notarized .dmg for local testing." >&2
        exit 1
    fi
fi

if [[ "$EXPORT_SIGNING_STYLE" != "automatic" && "$EXPORT_SIGNING_STYLE" != "manual" ]]; then
    echo "Unsupported EXPORT_SIGNING_STYLE: $EXPORT_SIGNING_STYLE" >&2
    echo "Expected 'automatic' or 'manual'." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"/*

if [[ -z "$MARKETING_VERSION" ]]; then
    MARKETING_VERSION="$(read_project_marketing_version)"
fi
ensure_semver "$MARKETING_VERSION"

if [[ -z "$BUILD_NUMBER" ]]; then
    BUILD_NUMBER="$(date +%Y%m%d%H%M)"
fi

TEAM_ID="$(resolve_team_id "$TEAM_ID" "$PROJECT_PATH" "$SCHEME" "$CONFIGURATION" "$EXPORT_SIGNING_STYLE" "$APP_PROVISIONING_PROFILE_SPECIFIER")"

auth_args=()
if [[ -n "$AUTH_KEY_PATH" && -n "$AUTH_KEY_ID" && -n "$AUTH_ISSUER_ID" ]]; then
    auth_args=(
        -authenticationKeyPath "$AUTH_KEY_PATH"
        -authenticationKeyID "$AUTH_KEY_ID"
        -authenticationKeyIssuerID "$AUTH_ISSUER_ID"
    )
fi

echo "==> Regenerating Xcode project"
"$PROJECT_DIR/scripts/regenerate-project.sh"

echo "==> Archiving $SCHEME ($MARKETING_VERSION/$BUILD_NUMBER) for Mac Catalyst"
archive_cmd=(
    xcodebuild
    -project "$PROJECT_PATH"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=macOS,variant=Mac Catalyst"
    -archivePath "$ARCHIVE_PATH"
    clean archive
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

if [[ -n "$TEAM_ID" ]]; then
    archive_cmd+=(DEVELOPMENT_TEAM="$TEAM_ID")
fi

if [[ "$EXPORT_SIGNING_STYLE" == "manual" ]]; then
    archive_cmd+=(
        APP_CODE_SIGN_STYLE=Manual
        APP_CODE_SIGN_IDENTITY="$APP_CODE_SIGN_IDENTITY"
    )
    if [[ -n "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
        archive_cmd+=(APP_PROVISIONING_PROFILE_SPECIFIER="$APP_PROVISIONING_PROFILE_SPECIFIER")
    fi
else
    archive_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
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
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>${EXPORT_SIGNING_STYLE}</string>
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
</dict>
</plist>
EOF

if [[ -n "$TEAM_ID" ]]; then
    /usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PLIST"
fi
if [[ "$EXPORT_SIGNING_STYLE" == "manual" && -n "$APP_PROVISIONING_PROFILE_SPECIFIER" ]]; then
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$EXPORT_OPTIONS_PLIST"
    /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROVISIONING_PROFILE_SPECIFIER" "$EXPORT_OPTIONS_PLIST"
fi

echo "==> Exporting Developer ID-signed .app"
export_cmd=(
    xcodebuild
    -exportArchive
    -archivePath "$ARCHIVE_PATH"
    -exportPath "$EXPORT_DIR"
    -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" ]]; then
    export_cmd+=(-allowProvisioningUpdates)
fi

if [[ "$EXPORT_SIGNING_STYLE" == "automatic" && "${#auth_args[@]}" -gt 0 ]]; then
    export_cmd+=("${auth_args[@]}")
fi

"${export_cmd[@]}"

# Exported path shape for developer-id is $EXPORT_DIR/<AppName>.app
APP_PATH="$(find "$EXPORT_DIR" -maxdepth 2 -type d -name "*.app" | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
    echo "No .app produced in $EXPORT_DIR" >&2
    exit 1
fi
echo "==> Exported app: $APP_PATH"

# Verify the .app signature before wrapping — catches missing/expired certs
# or broken provisioning profile embedding *before* we spend minutes on
# notarization.
echo "==> Verifying .app Developer ID signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH" || {
    echo "spctl assessment failed — app will not launch under Gatekeeper as-is." >&2
    echo "Usually means the signature is wrong (wrong cert type, not Developer ID)." >&2
    exit 1
}

DMG_NAME="${APP_DISPLAY_NAME}-${MARKETING_VERSION}-mac.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

echo "==> Building $DMG_NAME"
# UDZO = zlib-compressed read-only. Standard for distribution DMGs.
# -srcfolder packs the entire .app at the root of the mounted volume.
hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

echo "==> Signing .dmg with $APP_CODE_SIGN_IDENTITY"
codesign \
    --sign "$APP_CODE_SIGN_IDENTITY" \
    --timestamp \
    "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$SKIP_NOTARIZATION" == "1" ]]; then
    echo "==> Skipping notarization (SKIP_NOTARIZATION=1)"
    echo "==> Direct distribution build complete (UN-NOTARIZED)"
    echo "    DMG:         $DMG_PATH"
    echo "    Version:     $MARKETING_VERSION"
    echo "    Build:       $BUILD_NUMBER"
    echo
    echo "    NOTE: Gatekeeper will refuse to launch this .dmg on other Macs"
    echo "    until it is notarized."
    exit 0
fi

echo "==> Submitting $DMG_NAME to Apple's notary service (timeout: $NOTARIZATION_TIMEOUT)"
NOTARY_LOG="$BUILD_DIR/notarytool-submit.json"
if ! xcrun notarytool submit "$DMG_PATH" \
        --key "$AUTH_KEY_PATH" \
        --key-id "$AUTH_KEY_ID" \
        --issuer "$AUTH_ISSUER_ID" \
        --wait \
        --timeout "$NOTARIZATION_TIMEOUT" \
        --output-format json > "$NOTARY_LOG"; then
    echo "notarytool submission failed. Response:" >&2
    cat "$NOTARY_LOG" >&2 || true
    exit 1
fi

notary_status="$(jq -r '.status // empty' "$NOTARY_LOG")"
notary_id="$(jq -r '.id // empty' "$NOTARY_LOG")"
echo "==> Notary status: $notary_status (submission $notary_id)"

if [[ "$notary_status" != "Accepted" ]]; then
    echo "Notarization did not succeed. Fetching detailed log..." >&2
    if [[ -n "$notary_id" ]]; then
        xcrun notarytool log "$notary_id" \
            --key "$AUTH_KEY_PATH" \
            --key-id "$AUTH_KEY_ID" \
            --issuer "$AUTH_ISSUER_ID" \
            "$BUILD_DIR/notarytool-log.json" || true
        echo "Detailed log: $BUILD_DIR/notarytool-log.json" >&2
    fi
    exit 1
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

# Cross-check that the stapled ticket actually passes Gatekeeper offline.
# spctl on the .dmg confirms the container will be accepted; spctl on the
# mounted .app is the real "will this launch" check and is worth doing
# here in CI so a bad notarization fails the job rather than only failing
# on a user's Mac.
echo "==> Final Gatekeeper assessment on the .dmg"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

echo "==> Direct distribution build complete"
echo "    DMG:         $DMG_PATH"
echo "    Version:     $MARKETING_VERSION"
echo "    Build:       $BUILD_NUMBER"
echo "    Notary ID:   $notary_id"
