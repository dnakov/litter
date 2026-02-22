#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.sigkitten.litter}"
APP_STORE_APP_ID="${APP_STORE_APP_ID:-}"
INTERNAL_GROUP_NAME="${INTERNAL_GROUP_NAME:-Internal Testers}"

REVIEW_CONTACT_EMAIL="${REVIEW_CONTACT_EMAIL:-}"
REVIEW_CONTACT_FIRST_NAME="${REVIEW_CONTACT_FIRST_NAME:-}"
REVIEW_CONTACT_LAST_NAME="${REVIEW_CONTACT_LAST_NAME:-}"
REVIEW_CONTACT_PHONE="${REVIEW_CONTACT_PHONE:-}"
REVIEW_NOTES="${REVIEW_NOTES:-}"

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required command: $1" >&2
        exit 1
    fi
}

require_cmd asc
require_cmd jq

if [[ -z "$APP_STORE_APP_ID" ]]; then
    APP_STORE_APP_ID="$(
        asc apps list --bundle-id "$APP_BUNDLE_ID" --output json |
            jq -r '.data[0].id // empty'
    )"
fi

if [[ -z "$APP_STORE_APP_ID" ]]; then
    echo "Unable to resolve App Store Connect app id for bundle id: $APP_BUNDLE_ID" >&2
    exit 1
fi

echo "==> Using app id: $APP_STORE_APP_ID"

group_id="$(
    asc testflight beta-groups list --app "$APP_STORE_APP_ID" --output json |
        jq -r --arg name "$INTERNAL_GROUP_NAME" '.data[] | select(.attributes.name == $name) | .id' |
        head -n 1
)"

if [[ -z "$group_id" ]]; then
    echo "==> Creating internal TestFlight group: $INTERNAL_GROUP_NAME"
    group_id="$(
        asc testflight beta-groups create --app "$APP_STORE_APP_ID" --name "$INTERNAL_GROUP_NAME" --internal --output json |
            jq -r '.data.id // empty'
    )"
fi

echo "==> Internal beta group id: $group_id"

if [[ -n "$REVIEW_CONTACT_EMAIL" || -n "$REVIEW_CONTACT_FIRST_NAME" || -n "$REVIEW_CONTACT_LAST_NAME" || -n "$REVIEW_CONTACT_PHONE" || -n "$REVIEW_NOTES" ]]; then
    review_id="$(
        asc testflight review get --app "$APP_STORE_APP_ID" --output json |
            jq -r '.data[0].id // empty'
    )"
    if [[ -n "$review_id" ]]; then
        echo "==> Updating TestFlight beta review details"
        cmd=(asc testflight review update --id "$review_id" --output json)
        if [[ -n "$REVIEW_CONTACT_EMAIL" ]]; then
            cmd+=(--contact-email "$REVIEW_CONTACT_EMAIL")
        fi
        if [[ -n "$REVIEW_CONTACT_FIRST_NAME" ]]; then
            cmd+=(--contact-first-name "$REVIEW_CONTACT_FIRST_NAME")
        fi
        if [[ -n "$REVIEW_CONTACT_LAST_NAME" ]]; then
            cmd+=(--contact-last-name "$REVIEW_CONTACT_LAST_NAME")
        fi
        if [[ -n "$REVIEW_CONTACT_PHONE" ]]; then
            cmd+=(--contact-phone "$REVIEW_CONTACT_PHONE")
        fi
        if [[ -n "$REVIEW_NOTES" ]]; then
            cmd+=(--notes "$REVIEW_NOTES")
        fi
        "${cmd[@]}" >/dev/null
    fi
fi

echo "==> TestFlight setup complete"
