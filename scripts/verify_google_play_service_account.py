#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

from google.auth.exceptions import RefreshError
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account


ANDROID_PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"


def fail(message: str, exit_code: int = 1) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(exit_code)


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-key", required=True, help="Path to the Google service account JSON key")
    parser.add_argument("--package-name", required=True, help="Android application id, e.g. com.example.app")
    args = parser.parse_args()

    json_key_path = Path(args.json_key).expanduser().resolve()
    if not json_key_path.is_file():
        fail(f"JSON key not found: {json_key_path}")

    payload = load_service_account(json_key_path)

    print(f"JSON_KEY={json_key_path}")
    print(f"PROJECT_ID={payload['project_id']}")
    print(f"CLIENT_EMAIL={payload['client_email']}")
    print(f"PACKAGE_NAME={args.package_name}")

    try:
        credentials = service_account.Credentials.from_service_account_file(
            str(json_key_path),
            scopes=[ANDROID_PUBLISHER_SCOPE],
        )
        session = AuthorizedSession(credentials)
        response = session.post(
            f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{args.package_name}/edits",
            json={},
            timeout=30,
        )
    except RefreshError as exc:
        fail(
            "token exchange failed. This usually means the service account was deleted, the key is stale, "
            f"or the JSON key is invalid: {exc}"
        )
    except Exception as exc:
        fail(f"failed to contact Android Publisher API: {exc}")

    if response.status_code == 200:
        data = response.json()
        print("PLAY_PUBLISHING_ACCESS=OK")
        print(f"EDIT_ID={data.get('id', '')}")
        print(f"EXPIRY_TIME_SECONDS={data.get('expiryTimeSeconds', '')}")
        return

    try:
        data = response.json()
    except Exception:
        data = {"raw": response.text[:500]}

    print(f"HTTP_STATUS={response.status_code}")
    print(f"API_RESPONSE={json.dumps(data, ensure_ascii=True)}")

    if response.status_code == 403:
        fail(
            "the service account authenticated, but it does not have Android Publisher access for this app. "
            "Grant the service account access in Google Play Console > Users and permissions, "
            "and ensure the app already exists."
        )
    if response.status_code == 404:
        fail(
            "the package name was not found in Google Play. Ensure the Play app exists and the package "
            "name matches exactly."
        )
    fail("Google Play verification failed.")


if __name__ == "__main__":
    main()
