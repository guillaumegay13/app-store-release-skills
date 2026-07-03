#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

from google.auth.exceptions import RefreshError
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account


ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
RELEASE_STATUS_CHOICES = {"completed", "draft", "halted", "inProgress"}


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_service_account(json_key_path: Path) -> dict:
    try:
        payload = json.loads(json_key_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"failed to parse JSON key: {exc}")

    if payload.get("type") != "service_account":
        fail(f"unsupported credential type: {payload.get('type')!r}")

    required = ["project_id", "client_email", "private_key", "token_uri"]
    missing = [field for field in required if not payload.get(field)]
    if missing:
        fail(f"JSON key is missing required fields: {', '.join(missing)}")
    return payload


def load_release_notes(release_notes_path: Path | None) -> list[dict]:
    if release_notes_path is None:
        return []

    try:
        payload = json.loads(release_notes_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"failed to parse release notes JSON: {exc}")

    if not isinstance(payload, list):
        fail("release notes JSON must be a list of {language, text} objects")

    normalized: list[dict] = []
    for idx, entry in enumerate(payload):
        if not isinstance(entry, dict):
            fail(f"release note #{idx + 1} must be an object")
        language = str(entry.get("language") or "").strip()
        text = str(entry.get("text") or "").strip()
        if not language or not text:
            fail(f"release note #{idx + 1} must include non-empty language and text fields")
        normalized.append({"language": language, "text": text})
    return normalized


def parse_rollout(raw_rollout: str | None) -> float | None:
    if raw_rollout is None:
        return None
    try:
        rollout = float(raw_rollout)
    except ValueError as exc:
        fail(f"rollout must be a decimal between 0 and 1: {exc}")
    if rollout <= 0 or rollout >= 1:
        fail("rollout must be greater than 0 and less than 1")
    return rollout


def parse_json_response(response) -> dict:
    try:
        return response.json()
    except Exception:
        return {"raw": response.text[:2000]}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aab", required=True, help="Path to the Android App Bundle (.aab)")
    parser.add_argument("--json-key", required=True, help="Path to the Google service account JSON key")
    parser.add_argument("--package-name", required=True, help="Android application id, e.g. com.example.app")
    parser.add_argument(
        "--track",
        default="internal",
        choices=["internal", "alpha", "beta", "production"],
        help="Google Play track",
    )
    parser.add_argument(
        "--release-status",
        default="completed",
        help="Google Play release status: completed, draft, halted, or inProgress",
    )
    parser.add_argument("--release-name", help="Optional release name shown in Google Play")
    parser.add_argument(
        "--release-notes-json",
        help="Optional path to a JSON list of {language, text} release note objects",
    )
    parser.add_argument(
        "--rollout",
        help="Optional user fraction between 0 and 1. Only valid with --release-status inProgress",
    )
    args = parser.parse_args()

    aab_path = Path(args.aab).expanduser().resolve()
    json_key_path = Path(args.json_key).expanduser().resolve()
    release_notes_path = (
        Path(args.release_notes_json).expanduser().resolve()
        if args.release_notes_json
        else None
    )

    if not aab_path.is_file():
        fail(f"AAB not found: {aab_path}")
    if not json_key_path.is_file():
        fail(f"Google Play service account JSON not found: {json_key_path}")
    if release_notes_path is not None and not release_notes_path.is_file():
        fail(f"release notes JSON not found: {release_notes_path}")

    if args.release_status not in RELEASE_STATUS_CHOICES:
        fail(
            "release status must be one of: "
            + ", ".join(sorted(RELEASE_STATUS_CHOICES))
        )

    rollout = parse_rollout(args.rollout)
    if rollout is not None and args.release_status != "inProgress":
        fail("rollout can only be used with --release-status inProgress")

    payload = load_service_account(json_key_path)
    release_notes = load_release_notes(release_notes_path)

    print(f"JSON_KEY={json_key_path}")
    print(f"PROJECT_ID={payload['project_id']}")
    print(f"CLIENT_EMAIL={payload['client_email']}")
    print(f"AAB={aab_path}")
    print(f"PACKAGE_NAME={args.package_name}")
    print(f"TRACK={args.track}")
    print(f"RELEASE_STATUS={args.release_status}")

    try:
        credentials = service_account.Credentials.from_service_account_file(
            str(json_key_path),
            scopes=[ANDROID_PUBLISHER_SCOPE],
        )
        session = AuthorizedSession(credentials)
    except RefreshError as exc:
        fail(f"failed to initialize Android Publisher credentials: {exc}")
    except Exception as exc:
        fail(f"failed to initialize Android Publisher session: {exc}")

    base_url = "https://androidpublisher.googleapis.com/androidpublisher/v3"
    upload_base_url = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"

    edit_response = session.post(
        f"{base_url}/applications/{args.package_name}/edits",
        json={},
        timeout=120,
    )
    if edit_response.status_code != 200:
        data = parse_json_response(edit_response)
        fail(
            "failed to create Google Play edit "
            f"(HTTP {edit_response.status_code}): {json.dumps(data, ensure_ascii=True)}"
        )
    edit_id = edit_response.json()["id"]
    print(f"EDIT_ID={edit_id}")

    with aab_path.open("rb") as fh:
        upload_response = session.post(
            f"{upload_base_url}/applications/{args.package_name}/edits/{edit_id}/bundles?uploadType=media",
            data=fh,
            headers={"Content-Type": "application/octet-stream"},
            timeout=1800,
        )
    if upload_response.status_code != 200:
        data = parse_json_response(upload_response)
        fail(
            "failed to upload AAB to Google Play "
            f"(HTTP {upload_response.status_code}): {json.dumps(data, ensure_ascii=True)}"
        )

    bundle = upload_response.json()
    version_code = str(bundle["versionCode"])
    print(f"UPLOADED_VERSION_CODE={version_code}")
    print(f"BUNDLE_SHA1={bundle.get('sha1', '')}")
    print(f"BUNDLE_SHA256={bundle.get('sha256', '')}")

    release: dict[str, object] = {
        "versionCodes": [version_code],
        "status": args.release_status,
    }
    if args.release_name:
        release["name"] = args.release_name
    if release_notes:
        release["releaseNotes"] = release_notes
    if rollout is not None:
        release["userFraction"] = rollout

    track_response = session.put(
        f"{base_url}/applications/{args.package_name}/edits/{edit_id}/tracks/{args.track}",
        json={"track": args.track, "releases": [release]},
        timeout=120,
    )
    if track_response.status_code != 200:
        data = parse_json_response(track_response)
        fail(
            "failed to update Google Play track "
            f"(HTTP {track_response.status_code}): {json.dumps(data, ensure_ascii=True)}"
        )

    commit_response = session.post(
        f"{base_url}/applications/{args.package_name}/edits/{edit_id}:commit",
        params={"changesNotSentForReview": "true"},
        timeout=120,
    )
    if commit_response.status_code != 200:
        data = parse_json_response(commit_response)
        fail(
            "failed to commit Google Play edit "
            f"(HTTP {commit_response.status_code}): {json.dumps(data, ensure_ascii=True)}"
        )

    print(f"COMMIT_ID={commit_response.json().get('id', edit_id)}")
    print("ANDROID_UPLOAD=OK")


if __name__ == "__main__":
    main()
