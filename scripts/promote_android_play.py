#!/usr/bin/env python3
"""Promote an ALREADY-UPLOADED Android version code to a Google Play track.

Unlike upload_android_play_api.py, this does NOT upload a bundle. It assigns an
existing versionCode (already present in the app from a prior upload) to a track
and commits with changesNotSentForReview=true. The release is staged but NOT
sent for review — finish that step in the Play Console UI.
"""
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


def parse_json_response(response) -> dict:
    try:
        return response.json()
    except Exception:
        return {"raw": response.text[:2000]}


def parse_rollout(raw_rollout):
    if raw_rollout is None:
        return None
    try:
        rollout = float(raw_rollout)
    except ValueError as exc:
        fail(f"rollout must be a decimal between 0 and 1: {exc}")
    if rollout <= 0 or rollout >= 1:
        fail("rollout must be greater than 0 and less than 1")
    return rollout


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-key", required=True, help="Path to the Google service account JSON key")
    parser.add_argument("--package-name", required=True, help="Android application id, e.g. com.example.app")
    parser.add_argument("--version-code", required=True, help="Existing versionCode to promote")
    parser.add_argument("--track", default="production", help="Target track (production|beta|alpha|internal)")
    parser.add_argument("--release-status", default="completed", choices=sorted(RELEASE_STATUS_CHOICES))
    parser.add_argument("--release-name", help="Optional release name shown in Google Play")
    parser.add_argument("--rollout", help="Staged rollout fraction (0<f<1). Omit for full rollout.")
    args = parser.parse_args()

    json_key_path = Path(args.json_key).expanduser()
    if not json_key_path.is_file():
        fail(f"service account JSON not found: {json_key_path}")
    rollout = parse_rollout(args.rollout)

    print(f"PACKAGE_NAME={args.package_name}")
    print(f"PROMOTE_VERSION_CODE={args.version_code}")
    print(f"TRACK={args.track}")
    print(f"RELEASE_STATUS={args.release_status}")

    try:
        credentials = service_account.Credentials.from_service_account_file(
            str(json_key_path), scopes=[ANDROID_PUBLISHER_SCOPE]
        )
        session = AuthorizedSession(credentials)
    except RefreshError as exc:
        fail(f"failed to initialize Android Publisher credentials: {exc}")
    except Exception as exc:
        fail(f"failed to initialize Android Publisher session: {exc}")

    base_url = "https://androidpublisher.googleapis.com/androidpublisher/v3"

    edit_response = session.post(
        f"{base_url}/applications/{args.package_name}/edits", json={}, timeout=120
    )
    if edit_response.status_code != 200:
        data = parse_json_response(edit_response)
        fail(f"failed to create edit (HTTP {edit_response.status_code}): {json.dumps(data, ensure_ascii=True)}")
    edit_id = edit_response.json()["id"]
    print(f"EDIT_ID={edit_id}")

    release: dict[str, object] = {
        "versionCodes": [str(args.version_code)],
        "status": args.release_status,
    }
    if args.release_name:
        release["name"] = args.release_name
    if rollout is not None:
        release["userFraction"] = rollout

    track_response = session.put(
        f"{base_url}/applications/{args.package_name}/edits/{edit_id}/tracks/{args.track}",
        json={"track": args.track, "releases": [release]},
        timeout=120,
    )
    if track_response.status_code != 200:
        data = parse_json_response(track_response)
        fail(f"failed to update track (HTTP {track_response.status_code}): {json.dumps(data, ensure_ascii=True)}")

    commit_response = session.post(
        f"{base_url}/applications/{args.package_name}/edits/{edit_id}:commit",
        params={"changesNotSentForReview": "true"},
        timeout=120,
    )
    if commit_response.status_code != 200:
        data = parse_json_response(commit_response)
        fail(f"failed to commit edit (HTTP {commit_response.status_code}): {json.dumps(data, ensure_ascii=True)}")

    print(f"COMMIT_ID={commit_response.json().get('id', edit_id)}")
    print("ANDROID_PROMOTE=OK (staged, NOT sent for review — finish in Play Console UI)")


if __name__ == "__main__":
    main()
