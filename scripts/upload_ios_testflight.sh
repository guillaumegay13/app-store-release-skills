#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  upload_ios_testflight.sh --ipa PATH [--api-key-path PATH] [--api-key-p8 PATH --issuer-id UUID [--key-id ID]] [--apple-id EMAIL] [--app-identifier BUNDLE_ID] [--changelog TEXT] [--itc-provider PROVIDER] [--transport HTTP] [--log-level informational]

Notes:
  - Provide --api-key-path, or --api-key-p8 with --issuer-id, for App Store Connect API key auth.
  - API key auth uses Apple's Transporter CLI directly and does not require Fastlane.
  - When using Apple ID auth, fastlane may rely on your local session or FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD.
EOF
}

IPA_PATH=""
API_KEY_PATH=""
API_KEY_P8=""
KEY_ID=""
ISSUER_ID=""
APPLE_ID=""
APP_IDENTIFIER=""
CHANGELOG=""
ITC_PROVIDER=""
TRANSPORT="HTTP"
LOG_LEVEL="informational"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while (($# > 0)); do
  case "$1" in
    --ipa)
      [[ $# -ge 2 ]] || fail "--ipa requires a value."
      IPA_PATH="$2"
      shift 2
      ;;
    --api-key-path)
      [[ $# -ge 2 ]] || fail "--api-key-path requires a value."
      API_KEY_PATH="$2"
      shift 2
      ;;
    --api-key-p8)
      [[ $# -ge 2 ]] || fail "--api-key-p8 requires a value."
      API_KEY_P8="$2"
      shift 2
      ;;
    --key-id)
      [[ $# -ge 2 ]] || fail "--key-id requires a value."
      KEY_ID="$2"
      shift 2
      ;;
    --issuer-id)
      [[ $# -ge 2 ]] || fail "--issuer-id requires a value."
      ISSUER_ID="$2"
      shift 2
      ;;
    --apple-id)
      [[ $# -ge 2 ]] || fail "--apple-id requires a value."
      APPLE_ID="$2"
      shift 2
      ;;
    --app-identifier)
      [[ $# -ge 2 ]] || fail "--app-identifier requires a value."
      APP_IDENTIFIER="$2"
      shift 2
      ;;
    --changelog)
      [[ $# -ge 2 ]] || fail "--changelog requires a value."
      CHANGELOG="$2"
      shift 2
      ;;
    --itc-provider)
      [[ $# -ge 2 ]] || fail "--itc-provider requires a value."
      ITC_PROVIDER="$2"
      shift 2
      ;;
    --transport)
      [[ $# -ge 2 ]] || fail "--transport requires a value."
      TRANSPORT="$2"
      shift 2
      ;;
    --log-level)
      [[ $# -ge 2 ]] || fail "--log-level requires a value."
      LOG_LEVEL="$2"
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

[[ -n "$IPA_PATH" ]] || fail "--ipa is required."
[[ -f "$IPA_PATH" ]] || fail "IPA not found: $IPA_PATH"
[[ -n "$API_KEY_PATH" || -n "$API_KEY_P8" || -n "$APPLE_ID" ]] || fail "provide --api-key-path, or --api-key-p8 with --issuer-id, or --apple-id."

if [[ -n "$API_KEY_PATH" && -n "$API_KEY_P8" ]]; then
  fail "provide either --api-key-path or --api-key-p8, not both."
fi

if [[ -n "$API_KEY_PATH" ]]; then
  [[ -f "$API_KEY_PATH" ]] || fail "API key JSON not found: $API_KEY_PATH"
fi

cleanup() {
  if [[ -n "${TMP_IOS_UPLOAD_DIR:-}" && -d "${TMP_IOS_UPLOAD_DIR}" ]]; then
    rm -rf "${TMP_IOS_UPLOAD_DIR}"
  fi
  if [[ -n "${TMP_IOS_API_KEY_JSON:-}" && -f "${TMP_IOS_API_KEY_JSON}" ]]; then
    rm -f "${TMP_IOS_API_KEY_JSON}"
  fi
}
trap cleanup EXIT

infer_key_id_from_filename() {
  local key_filename
  key_filename="$(basename "$1")"
  if [[ "$key_filename" =~ ^AuthKey_([A-Za-z0-9]{10})\.p8$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

if [[ -n "$API_KEY_P8" ]]; then
  [[ -f "$API_KEY_P8" ]] || fail "App Store Connect .p8 key not found: $API_KEY_P8"
  [[ -n "$ISSUER_ID" ]] || fail "--issuer-id is required with --api-key-p8."
  if [[ -z "$KEY_ID" ]]; then
    KEY_ID="$(infer_key_id_from_filename "$API_KEY_P8")" || fail "could not infer --key-id from $(basename "$API_KEY_P8")"
  fi
  TMP_IOS_API_KEY_JSON="$(mktemp "${TMPDIR:-/tmp}/appstoreconnect.XXXXXX.json")"
  python3 "$SCRIPT_DIR/build_app_store_connect_api_key_json.py" \
    --p8-path "$API_KEY_P8" \
    --key-id "$KEY_ID" \
    --issuer-id "$ISSUER_ID" \
    --output "$TMP_IOS_API_KEY_JSON" >/dev/null
  API_KEY_PATH="$TMP_IOS_API_KEY_JSON"
fi

if [[ -n "$API_KEY_PATH" ]]; then
  TMP_IOS_UPLOAD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ios-upload.XXXXXX")"
  eval "$(
    python3 - "$API_KEY_PATH" "$TMP_IOS_UPLOAD_DIR" <<'PY'
import json
import re
import shlex
import sys
from pathlib import Path

api_key_json_path = Path(sys.argv[1]).expanduser().resolve()
tmp_dir = Path(sys.argv[2]).resolve()

payload = json.loads(api_key_json_path.read_text(encoding="utf-8"))
key_id = str(payload.get("key_id") or "").strip()
issuer_id = str(payload.get("issuer_id") or "").strip()
private_key = str(payload.get("key") or "")

if not re.fullmatch(r"[A-Z0-9]{10}", key_id):
    raise SystemExit("invalid key_id in App Store Connect API key JSON")
if not re.fullmatch(
    r"[0-9a-fA-F]{8}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{12}",
    issuer_id,
):
    raise SystemExit("invalid issuer_id in App Store Connect API key JSON")
if "BEGIN PRIVATE KEY" not in private_key or "END PRIVATE KEY" not in private_key:
    raise SystemExit("invalid key in App Store Connect API key JSON")

private_keys_dir = tmp_dir / "private_keys"
private_keys_dir.mkdir(parents=True, exist_ok=True)
private_keys_dir.chmod(0o700)
key_path = private_keys_dir / f"AuthKey_{key_id}.p8"
key_path.write_text(private_key.rstrip() + "\n", encoding="utf-8")
key_path.chmod(0o600)

print(f"TRANSPORTER_KEY_ID={shlex.quote(key_id)}")
print(f"TRANSPORTER_ISSUER_ID={shlex.quote(issuer_id)}")
PY
  )"

  declare -a transporter_cmd
  if command -v iTMSTransporter >/dev/null 2>&1; then
    transporter_cmd=(iTMSTransporter)
  elif command -v xcrun >/dev/null 2>&1; then
    transporter_cmd=(xcrun iTMSTransporter)
  elif [[ -x /Applications/Transporter.app/Contents/itms/bin/iTMSTransporter ]]; then
    transporter_cmd=(/Applications/Transporter.app/Contents/itms/bin/iTMSTransporter)
  else
    fail "iTMSTransporter is not installed or not in PATH."
  fi

  if [[ -n "$ITC_PROVIDER" ]]; then
    echo "INFO: ignoring --itc-provider because Transporter API key uploads do not accept provider selection." >&2
  fi
  if [[ -n "$CHANGELOG" ]]; then
    echo "INFO: ignoring --changelog because Transporter only uploads the IPA; beta metadata must be managed separately." >&2
  fi
  if [[ -n "$APP_IDENTIFIER" ]]; then
    echo "INFO: ignoring --app-identifier because Transporter resolves the app from the IPA bundle id." >&2
  fi

  declare -a cmd=(
    "${transporter_cmd[@]}"
    -m upload
    -assetFile "$IPA_PATH"
    -apiKey "$TRANSPORTER_KEY_ID"
    -apiIssuer "$TRANSPORTER_ISSUER_ID"
    -t "$TRANSPORT"
    -v "$LOG_LEVEL"
  )

  printf 'Running:'
  printf ' %q' "${cmd[@]}"
  printf '\n'

  (
    cd "$TMP_IOS_UPLOAD_DIR"
    "${cmd[@]}"
  )
  exit 0
fi

command -v fastlane >/dev/null 2>&1 || fail "fastlane is not installed or not in PATH."
[[ -n "$APP_IDENTIFIER" ]] || fail "--app-identifier is required for the Apple ID (fastlane) upload path, e.g. com.example.app"

declare -a cmd=(fastlane run pilot "ipa:$IPA_PATH" "app_identifier:$APP_IDENTIFIER" "skip_submission:true" "skip_waiting_for_build_processing:true")

if [[ -n "$APPLE_ID" ]]; then
  cmd+=("apple_id:$APPLE_ID")
fi

if [[ -n "$CHANGELOG" ]]; then
  cmd+=("changelog:$CHANGELOG")
fi

if [[ -n "$ITC_PROVIDER" ]]; then
  cmd+=("itc_provider:$ITC_PROVIDER")
fi

printf 'Running:'
printf ' %q' "${cmd[@]}"
printf '\n'
"${cmd[@]}"
