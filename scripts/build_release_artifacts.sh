#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  build_release_artifacts.sh [--app-dir PATH] [--env-file PATH] [--use-staging] [--skip-ios] [--skip-android] [-- FLUTTER_ARGS...]

Examples:
  build_release_artifacts.sh --app-dir /path/to/train-flutter-app --env-file .env
  build_release_artifacts.sh --app-dir /path/to/train-flutter-app --env-file .env --use-staging -- --build-name=6.0.5 --build-number=155
EOF
}

trim_trailing_cr() {
  printf '%s' "${1%$'\r'}"
}

APP_DIR="$(pwd)"
ENV_FILE=".env"
USE_STAGING=0
BUILD_IOS=1
BUILD_ANDROID=1
declare -a FLUTTER_ARGS=()

while (($# > 0)); do
  case "$1" in
    --app-dir)
      [[ $# -ge 2 ]] || fail "--app-dir requires a value."
      APP_DIR="$2"
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || fail "--env-file requires a value."
      ENV_FILE="$2"
      shift 2
      ;;
    --use-staging)
      USE_STAGING=1
      shift
      ;;
    --skip-ios)
      BUILD_IOS=0
      shift
      ;;
    --skip-android)
      BUILD_ANDROID=0
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      FLUTTER_ARGS+=("$@")
      break
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

(( BUILD_IOS == 1 || BUILD_ANDROID == 1 )) || fail "nothing to build; remove --skip-ios or --skip-android."

[[ -d "$APP_DIR" ]] || fail "app directory not found: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"
[[ -f "$APP_DIR/pubspec.yaml" ]] || fail "pubspec.yaml not found in $APP_DIR"

if [[ "$ENV_FILE" != /* ]]; then
  ENV_FILE="$APP_DIR/$ENV_FILE"
fi
[[ -f "$ENV_FILE" ]] || fail "env file not found: $ENV_FILE"

command -v flutter >/dev/null 2>&1 || fail "flutter is not installed or not in PATH."

if (( BUILD_ANDROID == 1 )); then
  key_properties_file="$APP_DIR/key.properties"
  [[ -f "$key_properties_file" ]] || fail "Android release build requires key.properties in $APP_DIR."

  store_file_raw="$(awk -F= '/^storeFile=/{print $2; exit}' "$key_properties_file")"
  store_file_raw="$(trim_trailing_cr "$store_file_raw")"
  [[ -n "$store_file_raw" ]] || fail "key.properties is missing storeFile."

  if [[ "$store_file_raw" =~ ^[A-Za-z]:[\\/].* ]]; then
    keystore_path="$store_file_raw"
  elif [[ "$store_file_raw" = /* ]]; then
    keystore_path="$store_file_raw"
  else
    keystore_path="$APP_DIR/$store_file_raw"
  fi

  [[ -f "$keystore_path" ]] || fail "Android keystore file referenced by key.properties does not exist on this machine."
fi

cd "$APP_DIR"

version="$(awk '/^version: /{print $2; exit}' pubspec.yaml)"
ios_ipa=""
android_aab=""

if (( BUILD_IOS == 1 )); then
  echo "Building iOS IPA..."
  if [[ -f "$APP_DIR/scripts/build_ios_ipa.sh" ]]; then
    # Repo-provided build gate: keeps any project-specific Xcode/SDK guardrails.
    # It is expected to translate --env-file into dart-defines itself.
    declare -a ios_args=(--env-file "$ENV_FILE")
    if (( USE_STAGING == 1 )); then
      ios_args+=(--dart-define=USE_STAGING=true)
    fi
    ios_args+=(${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"})
    bash "$APP_DIR/scripts/build_ios_ipa.sh" "${ios_args[@]}"
  else
    # Native fallback for any Flutter app: plain `flutter build ipa`.
    declare -a ios_args=(build ipa --release "--dart-define-from-file=$ENV_FILE")
    if (( USE_STAGING == 1 )); then
      ios_args+=(--dart-define=USE_STAGING=true)
    fi
    ios_args+=(${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"})
    flutter "${ios_args[@]}"
  fi

  shopt -s nullglob
  ipa_candidates=("$APP_DIR"/build/ios/ipa/*.ipa)
  shopt -u nullglob
  if ((${#ipa_candidates[@]} > 0)); then
    ios_ipa="$(LC_ALL=C ls -t "${ipa_candidates[@]}" 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "$ios_ipa" ]] || fail "iOS build completed but no IPA was found under $APP_DIR/build/ios/ipa."
fi

if (( BUILD_ANDROID == 1 )); then
  declare -a android_args=(build appbundle "--dart-define-from-file=$ENV_FILE")
  if (( USE_STAGING == 1 )); then
    android_args+=(--dart-define=USE_STAGING=true)
  fi
  android_args+=(${FLUTTER_ARGS[@]+"${FLUTTER_ARGS[@]}"})

  echo "Building Android App Bundle..."
  flutter "${android_args[@]}"

  android_aab="$APP_DIR/build/app/outputs/bundle/release/app-release.aab"
  if [[ ! -f "$android_aab" ]]; then
    shopt -s globstar nullglob
    aab_candidates=("$APP_DIR"/build/app/outputs/bundle/**/*.aab)
    shopt -u globstar nullglob
    if ((${#aab_candidates[@]} > 0)); then
      android_aab="$(LC_ALL=C ls -t "${aab_candidates[@]}" 2>/dev/null | head -n 1 || true)"
    else
      android_aab=""
    fi
  fi
  [[ -n "$android_aab" ]] || fail "Android build completed but no AAB was found under $APP_DIR/build/app/outputs/bundle."
fi

printf 'APP_DIR=%s\n' "$APP_DIR"
printf 'VERSION=%s\n' "${version:-unknown}"
printf 'ENV_FILE=%s\n' "$ENV_FILE"
if (( USE_STAGING == 1 )); then
  printf 'USE_STAGING=%s\n' "true"
else
  printf 'USE_STAGING=%s\n' "false"
fi
if [[ -n "$ios_ipa" ]]; then
  printf 'IOS_IPA=%s\n' "$ios_ipa"
fi
if [[ -n "$android_aab" ]]; then
  printf 'ANDROID_AAB=%s\n' "$android_aab"
fi
