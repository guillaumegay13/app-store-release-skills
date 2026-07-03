#!/usr/bin/env python3
import argparse
import json
import re
import sys
from pathlib import Path


UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{12}$"
)
KEY_ID_RE = re.compile(r"^[A-Z0-9]{10}$")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--p8-path", required=True, help="Path to AuthKey_XXXXXXXXXX.p8")
    parser.add_argument("--key-id", required=True, help="App Store Connect API key id")
    parser.add_argument("--issuer-id", required=True, help="App Store Connect issuer UUID")
    parser.add_argument("--output", required=True, help="Destination JSON path")
    parser.add_argument("--duration", type=int, default=1200, help="JWT duration in seconds")
    parser.add_argument("--in-house", action="store_true", help="Set in_house=true for enterprise accounts")
    args = parser.parse_args()

    p8_path = Path(args.p8_path).expanduser().resolve()
    output_path = Path(args.output).expanduser().resolve()

    if not p8_path.is_file():
        fail(f"p8 key not found: {p8_path}")
    if not KEY_ID_RE.fullmatch(args.key_id):
        fail("key id must be the 10-character App Store Connect key id, for example 6CWNM6CNJF")
    if not UUID_RE.fullmatch(args.issuer_id):
        fail("issuer id must be a UUID, for example 00000000-1111-2222-3333-444444444444")
    if args.duration <= 0:
        fail("duration must be greater than 0")

    key_text = p8_path.read_text(encoding="utf-8").strip() + "\n"
    if "BEGIN PRIVATE KEY" not in key_text or "END PRIVATE KEY" not in key_text:
        fail(f"{p8_path} does not look like a valid App Store Connect .p8 key")

    payload = {
        "key_id": args.key_id,
        "issuer_id": args.issuer_id,
        "key": key_text,
        "duration": args.duration,
        "in_house": args.in_house,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

    print(f"APP_STORE_CONNECT_JSON={output_path}")
    print(f"KEY_ID={args.key_id}")
    print(f"ISSUER_ID={args.issuer_id}")
    print(f"IN_HOUSE={str(args.in_house).lower()}")
    print(f"DURATION={args.duration}")


if __name__ == "__main__":
    main()
