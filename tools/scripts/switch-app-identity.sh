#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

IOS_PROJECT_YML="$REPO_DIR/apps/ios/project.yml"
THIS_SCRIPT_RELATIVE="tools/scripts/switch-app-identity.sh"
IOS_XCODEPROJ_DIR_RELATIVE="apps/ios/Litter.xcodeproj/"

TARGET=""
IDENTIFIER=""
TEAM_ID=""
TEAM_ID_SET=0
RUN_XCODEGEN=1

usage() {
  cat <<'EOF'
Usage: ./tools/scripts/switch-app-identity.sh --to <sigkitten|your-identifier> [options]

Switches local app identifiers between:
  - com.sigkitten.litter(.android|.remote)
  - com.<your-identifier>.litter(.android|.remote)

Options:
  --to <sigkitten|your-identifier>
                            Target app identity prefix.
  --identifier <name>       Required with --to your-identifier.
                            Example: --identifier makyinc
  --team-id <id|none>       Set iOS DEVELOPMENT_TEAM in apps/ios/project.yml.
                            Pass "none" to remove DEVELOPMENT_TEAM lines.
  --no-xcodegen             Skip regenerating apps/ios/Litter.xcodeproj.
  -h, --help                Show this help.
EOF
}

while [ "${1:-}" != "" ]; do
  case "$1" in
    --to)
      TARGET="${2:-}"
      shift 2
      ;;
    --identifier)
      IDENTIFIER="${2:-}"
      if [ -z "$IDENTIFIER" ]; then
        echo "error: --identifier requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --team-id)
      TEAM_ID_SET=1
      TEAM_ID="${2:-}"
      if [ -z "$TEAM_ID" ]; then
        echo "error: --team-id requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --no-xcodegen)
      RUN_XCODEGEN=0
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

if [ -z "$TARGET" ]; then
  echo "error: --to is required" >&2
  usage >&2
  exit 1
fi

case "$TARGET" in
  sigkitten)
    TARGET_IDENTIFIER="sigkitten"
    ;;
  your-identifier)
    if [ -z "$IDENTIFIER" ]; then
      echo "error: --identifier is required when --to your-identifier" >&2
      exit 1
    fi
    TARGET_IDENTIFIER="$IDENTIFIER"
    ;;
  *)
    echo "error: --to must be one of: sigkitten, your-identifier" >&2
    exit 1
    ;;
esac

if ! [[ "$TARGET_IDENTIFIER" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "error: identifier must match ^[a-z][a-z0-9_]*$ (example: makyinc)" >&2
  exit 1
fi

detect_current_identifier() {
  local current=""

  if [ -f "$IOS_PROJECT_YML" ]; then
    current="$(sed -nE 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*com\.([a-z0-9_]+)\.litter(\.remote)?[[:space:]]*$/\1/p' "$IOS_PROJECT_YML" | head -n1)"
  fi

  if [ -z "$current" ] && [ -f "$REPO_DIR/apps/android/app/build.gradle.kts" ]; then
    current="$(sed -nE 's/^[[:space:]]*namespace[[:space:]]*=[[:space:]]*"com\.([a-z0-9_]+)\.litter\.android"[[:space:]]*$/\1/p' "$REPO_DIR/apps/android/app/build.gradle.kts" | head -n1)"
  fi

  if [ -z "$current" ]; then
    echo "error: could not detect current identifier from project files" >&2
    exit 1
  fi

  printf '%s\n' "$current"
}

replace_in_tracked_files() {
  local from="$1"
  local to="$2"
  local changed=0

  while IFS= read -r -d '' relative; do
    if [ "$relative" = "$THIS_SCRIPT_RELATIVE" ] || [ "$relative" = "./$THIS_SCRIPT_RELATIVE" ]; then
      continue
    fi
    if [[ "$relative" == "$IOS_XCODEPROJ_DIR_RELATIVE"* ]] || [[ "$relative" == "./$IOS_XCODEPROJ_DIR_RELATIVE"* ]]; then
      continue
    fi
    perl -0pi -e "s/\Q$from\E/$to/g" "$REPO_DIR/$relative"
    changed=1
  done < <(cd "$REPO_DIR" && git grep -zl -- "$from" || true)

  if [ "$changed" -eq 1 ]; then
    echo "Replaced '$from' -> '$to'"
    echo "Skipped direct edits under $IOS_XCODEPROJ_DIR_RELATIVE (uses project.yml + xcodegen)"
  else
    echo "No occurrences of '$from' found in tracked files"
  fi
}

CURRENT_IDENTIFIER="$(detect_current_identifier)"
FROM_PREFIX="com.${CURRENT_IDENTIFIER}.litter"
TO_PREFIX="com.${TARGET_IDENTIFIER}.litter"

if [ "$FROM_PREFIX" = "$TO_PREFIX" ]; then
  echo "Identifier already set to '$TARGET_IDENTIFIER'; no prefix replacement needed"
else
  replace_in_tracked_files "$FROM_PREFIX" "$TO_PREFIX"
fi

set_ios_development_team() {
  local team="$1"
  local file="$IOS_PROJECT_YML"

  if [ ! -f "$file" ]; then
    echo "warning: $file not found, skipping iOS team update" >&2
    return
  fi

  perl -0pi -e 's/^[ \t]{8}DEVELOPMENT_TEAM:[^\n]*\n//mg' "$file"

  if [ "$team" != "none" ]; then
    TEAM_VALUE="$team" perl -0pi -e 's/(^[ \t]{8}ASSETCATALOG_COMPILER_APPICON_NAME:[^\n]*\n)/$1 . "        DEVELOPMENT_TEAM: $ENV{TEAM_VALUE}\n"/mge' "$file"
    echo "Set iOS DEVELOPMENT_TEAM=$team in apps/ios/project.yml"
  else
    echo "Removed iOS DEVELOPMENT_TEAM from apps/ios/project.yml"
  fi
}

regenerate_xcode_project() {
  if [ "$RUN_XCODEGEN" -eq 0 ]; then
    echo "Skipped xcodegen (--no-xcodegen)"
    return
  fi

  if ! command -v xcodegen >/dev/null 2>&1; then
    echo "warning: xcodegen not found; skipped regenerating apps/ios/Litter.xcodeproj" >&2
    return
  fi

  (
    cd "$REPO_DIR"
    xcodegen generate --spec apps/ios/project.yml --project apps/ios/Litter.xcodeproj >/dev/null
  )
  echo "Regenerated apps/ios/Litter.xcodeproj from apps/ios/project.yml"
}

if [ "$TEAM_ID_SET" -eq 1 ]; then
  set_ios_development_team "$TEAM_ID"
fi

regenerate_xcode_project

echo "Done."
echo "Review changes with:"
echo "  git -C \"$REPO_DIR\" status --short"
echo "  git -C \"$REPO_DIR\" diff -- apps/android/app/build.gradle.kts apps/ios/project.yml apps/ios/Litter.xcodeproj/project.pbxproj"
