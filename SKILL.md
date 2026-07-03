---
name: app-store-release-skills
description: Use when building and publishing a mobile app to the App Store (TestFlight) or Google Play from the command line. Builds signed iOS/Android artifacts and uploads them with App Store Connect API keys and the Google Play Publishing API. App-agnostic — configured per app via flags or a release-config.env, no vendor lock-in, no Fastlane required for the primary paths.
metadata:
  author: guillaumegay13
  version: "1.0"
---

# App Store Release

Build and publish a mobile app to TestFlight and Google Play from the command
line. Every script is driven by flags (or an optional `release-config.env`), so
the same skill works for any app once its credentials and signing are in place.

## What this does and does not do

- Does: build signed artifacts (Flutter), upload an `.ipa` to TestFlight, upload
  an `.aab` to a Google Play track, promote an existing Android version code,
  and verify credentials before you rely on them.
- Does not: create the App Store Connect or Play Console app record for the first
  time, or push localized store metadata / release notes on iOS. Those are
  manual, one-time steps — do them in the consoles, then automate everything after.

## Prerequisites

- `flutter` on PATH (only for the build step; uploads accept any prebuilt artifact).
- iOS build/sign: macOS with Xcode. Uploading a prebuilt `.ipa` can run anywhere
  Apple Transporter (`xcrun iTMSTransporter` or Transporter.app) is installed.
- Android: `python3` with `google-auth` (`pip install google-auth`).
- The app record must already exist in App Store Connect and Play Console.

## Credentials (per app — never commit these)

| Platform | You need | Where it comes from |
|----------|----------|---------------------|
| iOS | `.p8` API key + Key ID + Issuer ID (or a prebuilt API-key JSON) | App Store Connect → Users and Access → Integrations → App Store Connect API |
| iOS | Signing certificate + provisioning profile | Xcode / Apple Developer account |
| Android | Service account JSON with Play Publishing access | Google Cloud service account, granted in Play Console → Users and permissions |
| Android | Upload keystore (`.jks`) referenced by `key.properties` | Generated once with `keytool`, kept on the build machine |

Copy `release-config.example.env` to `release-config.env`, fill it in, and keep
it out of git (`.gitignore` already covers it). See `README.md` for step-by-step
credential setup.

## Workflow

Announce which step you are on and never claim an app was published unless the
upload step actually returned success.

### 1. Verify credentials first

```bash
python3 scripts/verify_google_play_service_account.py \
  --json-key /abs/path/to/google-play-service-account.json \
  --package-name com.example.app
```

For iOS, if you only have a `.p8`, assemble the API-key JSON once:

```bash
python3 scripts/build_app_store_connect_api_key_json.py \
  --p8-path /abs/path/to/AuthKey_XXXXXXXXXX.p8 \
  --key-id XXXXXXXXXX \
  --issuer-id 00000000-1111-2222-3333-444444444444 \
  --output /abs/path/to/appstoreconnect.json
```

### 2. Bump the version, then build

Set the version in `pubspec.yaml` (Google Play rejects a reused version code).
Then build signed artifacts:

```bash
bash scripts/build_release_artifacts.sh --app-dir /abs/path/to/app --env-file .env
# add --skip-ios or --skip-android to build one platform
# pass extra Flutter flags after --, e.g.  -- --build-name=1.2.3 --build-number=45
```

Read the printed `IOS_IPA=` and `ANDROID_AAB=` lines — those are the paths to upload.
If the app repo provides `scripts/build_ios_ipa.sh`, it is used (to keep any
project-specific Xcode guardrails); otherwise a native `flutter build ipa` runs.

### 3. Upload

iOS → TestFlight (Transporter, API-key auth):

```bash
bash scripts/upload_ios_testflight.sh \
  --ipa /abs/path/to/app.ipa \
  --api-key-path /abs/path/to/appstoreconnect.json
# or straight from a .p8:
#   --api-key-p8 /abs/path/to/AuthKey_XXXXXXXXXX.p8 --issuer-id <UUID> --key-id <ID>
```

Android → Google Play track:

```bash
bash scripts/upload_android_play.sh \
  --aab /abs/path/to/app-release.aab \
  --json-key /abs/path/to/google-play-service-account.json \
  --package-name com.example.app \
  --track internal
# optional: --release-name 1.2.3 --release-notes-json notes.json --rollout 0.2 --release-status inProgress
```

### 4. Promote (Android, optional)

Move an already-uploaded version code to another track (staged, not sent for review):

```bash
python3 scripts/promote_android_play.py \
  --json-key /abs/path/to/google-play-service-account.json \
  --package-name com.example.app \
  --version-code 45 --track production --rollout 0.1 --release-status inProgress
```

## Gotchas

- Transporter uploads the binary only. Localized App Store release notes and
  "What to Test" are a separate step — do not claim they were pushed.
- With API-key auth, do not pass a provider short name; Apple rejects
  `-asc_provider` together with `-apiKey`.
- `Version code N has already been used` → bump the version in `pubspec.yaml`,
  rebuild (use `--skip-ios` for an Android-only rebuild), and re-upload.
- Preserve non-ASCII characters (accents, etc.) in any release notes or metadata.
- Google Play commits use `changesNotSentForReview=true`: the release is staged;
  finish "send for review" in the Play Console, or in your release process.
