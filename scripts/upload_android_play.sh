#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  upload_android_play.sh --aab PATH --json-key PATH [--package-name ID] [--track internal|alpha|beta|production] [--release-status STATUS] [--release-name NAME] [--release-notes-json PATH] [--rollout FRACTION]
EOF
}

AAB_PATH=""
JSON_KEY_PATH=""
PACKAGE_NAME=""
TRACK="internal"
RELEASE_STATUS=""
RELEASE_NAME=""
RELEASE_NOTES_JSON=""
ROLLOUT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while (($# > 0)); do
  case "$1" in
    --aab)
      [[ $# -ge 2 ]] || fail "--aab requires a value."
      AAB_PATH="$2"
      shift 2
      ;;
    --json-key)
      [[ $# -ge 2 ]] || fail "--json-key requires a value."
      JSON_KEY_PATH="$2"
      shift 2
      ;;
    --package-name)
      [[ $# -ge 2 ]] || fail "--package-name requires a value."
      PACKAGE_NAME="$2"
      shift 2
      ;;
    --track)
      [[ $# -ge 2 ]] || fail "--track requires a value."
      TRACK="$2"
      shift 2
      ;;
    --release-status)
      [[ $# -ge 2 ]] || fail "--release-status requires a value."
      RELEASE_STATUS="$2"
      shift 2
      ;;
    --release-name)
      [[ $# -ge 2 ]] || fail "--release-name requires a value."
      RELEASE_NAME="$2"
      shift 2
      ;;
    --release-notes-json)
      [[ $# -ge 2 ]] || fail "--release-notes-json requires a value."
      RELEASE_NOTES_JSON="$2"
      shift 2
      ;;
    --rollout)
      [[ $# -ge 2 ]] || fail "--rollout requires a value."
      ROLLOUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[[ -n "$AAB_PATH" ]] || fail "--aab is required."
[[ -f "$AAB_PATH" ]] || fail "AAB not found: $AAB_PATH"
[[ -n "$JSON_KEY_PATH" ]] || fail "--json-key is required."
[[ -f "$JSON_KEY_PATH" ]] || fail "Google Play service account JSON not found: $JSON_KEY_PATH"
[[ -n "$PACKAGE_NAME" ]] || fail "--package-name is required, e.g. com.example.app"

declare -a cmd=(
  python3
  "$SCRIPT_DIR/upload_android_play_api.py"
  --aab "$AAB_PATH"
  --json-key "$JSON_KEY_PATH"
  --package-name "$PACKAGE_NAME"
  --track "$TRACK"
)

if [[ -n "$RELEASE_STATUS" ]]; then
  cmd+=(--release-status "$RELEASE_STATUS")
fi

if [[ -n "$RELEASE_NAME" ]]; then
  cmd+=(--release-name "$RELEASE_NAME")
fi

if [[ -n "$RELEASE_NOTES_JSON" ]]; then
  cmd+=(--release-notes-json "$RELEASE_NOTES_JSON")
fi

if [[ -n "$ROLLOUT" ]]; then
  cmd+=(--rollout "$ROLLOUT")
fi

printf 'Running:'
printf ' %q' "${cmd[@]}"
printf '\n'
"${cmd[@]}"
