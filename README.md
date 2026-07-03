# App Store Release Skills

An AI-agent skill (and a set of standalone scripts) that **builds and publishes a
mobile app to TestFlight and Google Play from the command line** — using App Store
Connect API keys and the Google Play Publishing API directly. No Fastlane required
for the primary paths, no CI minutes needed, no vendor lock-in.

It is **app-agnostic**: nothing about any specific app is baked in. You configure
it per app with flags or a `release-config.env`, and the same skill works for
every app you ship.

## Install (as a skill)

```bash
npx skills add guillaumegay13/app-store-release-skills
```

Any agent that reads `SKILL.md` can then run the workflow. The `scripts/` are
plain Bash/Python and work standalone too — you do not need an agent to use them.

## What it does

- Build signed iOS `.ipa` and Android `.aab` (Flutter).
- Upload the `.ipa` to TestFlight via Apple Transporter + an ASC API key.
- Upload the `.aab` to any Google Play track via the Publishing API.
- Promote an existing Android version code between tracks (staged rollout supported).
- Verify credentials and assemble the ASC API-key JSON.

## What it does not do

- Create the App Store Connect / Play Console app record for the **first** time.
- Push localized App Store metadata or release notes (iOS binary upload only).

Those are one-time manual console steps. Everything after is automatable.

## How it works

1. **Verify** your Play service account and (optionally) assemble the ASC key JSON.
2. **Bump the version** in `pubspec.yaml`.
3. **Build** signed artifacts with `build_release_artifacts.sh`.
4. **Upload** to TestFlight and/or a Google Play track.
5. **Promote** the Android build to another track when you are ready.

Full step-by-step commands live in [`SKILL.md`](SKILL.md).

## One-time setup

### 1. App Store Connect API key (iOS)

1. App Store Connect → **Users and Access → Integrations → App Store Connect API**.
2. Create a key with **App Manager** access. Download the `.p8` **once** (you can't re-download it).
3. Note the **Key ID** (10 chars) and the **Issuer ID** (a UUID at the top of the page).
4. Optionally pre-build the JSON some tools expect:

   ```bash
   python3 scripts/build_app_store_connect_api_key_json.py \
     --p8-path ~/keys/AuthKey_XXXXXXXXXX.p8 \
     --key-id XXXXXXXXXX \
     --issuer-id 00000000-1111-2222-3333-444444444444 \
     --output ~/keys/appstoreconnect.json
   ```

You also need **iOS signing** set up in Xcode (a distribution certificate and a
provisioning profile for the bundle id). Building/signing iOS requires macOS + Xcode.

### 2. Google Play service account (Android)

1. In Google Cloud, create a **service account** and download a **JSON key**.
2. In **Play Console → Users and permissions**, invite that service account's
   email and grant it release permissions for the app.
3. Verify access against your real package:

   ```bash
   python3 scripts/verify_google_play_service_account.py \
     --json-key ~/keys/google-play-service-account.json \
     --package-name com.example.app
   ```

   `PLAY_PUBLISHING_ACCESS=OK` means you're ready. `403`/`404` messages tell you
   exactly what to fix.

Install the Python dependency once: `pip install google-auth`.

### 3. Android signing keystore

Generate an upload keystore once and reference it from `<app>/key.properties`:

```bash
keytool -genkey -v -keystore ~/upload-keystore.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

```properties
# <app>/key.properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

The build fails fast if the keystore referenced here doesn't exist on the machine.

### 4. Per-app config

```bash
cp release-config.example.env release-config.env
# edit release-config.env with your paths / ids
```

`release-config.env` is gitignored. Never commit `.p8` keys, service-account JSON,
keystores, or `.env` files.

## Requirements

- Flutter (build step only; uploads accept any prebuilt artifact).
- macOS + Xcode for iOS build/sign. iOS *upload* runs anywhere Transporter exists.
- `python3` + `google-auth` for Android.

## Security

This repo ships **only scripts and docs** — no credentials. Every secret is
supplied at runtime by path. The `.gitignore` blocks the common credential and
artifact file types. Treat your `.p8`, service-account JSON, and keystores as
secrets and store them outside the repo.

## License

MIT — see [LICENSE](LICENSE).
