#!/usr/bin/env python3
"""Restore WezCrypt backups on a computer using only the recovery key.

    python3 wezcrypt_restore.py --server https://studio.rextv.sbs --username me --out ./restored
    (prompts for the password and the recovery key; or use --api-key-stdin)

Every file is decrypted locally, each segment is authenticated, and the
plaintext SHA-256 is compared with the value recorded in the encrypted manifest
before the file is written to its final name.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import logging
import os
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from wzce import VaultKeys, WZCEError, decrypt_bytes, decrypt_stream, parse_recovery_key  # noqa: E402

log = logging.getLogger("wezcrypt_restore")


class Client:
    def __init__(self, server: str, token: str | None = None, timeout: float = 120) -> None:
        parsed = urllib.parse.urlparse(server)
        if parsed.scheme != "https" and parsed.hostname not in {"127.0.0.1", "localhost"}:
            raise SystemExit("refusing to use a non-HTTPS server")
        self.base = server.rstrip("/")
        self.token = token
        self.timeout = timeout

    def request(self, method: str, path: str, body: dict | None = None, headers: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        for key, value in (headers or {}).items():
            req.add_header(key, value)
        try:
            return urllib.request.urlopen(req, timeout=self.timeout)  # noqa: S310 - https enforced above
        except urllib.error.HTTPError as exc:
            try:
                detail = json.loads(exc.read()).get("error", {}).get("message", "")
            except Exception:  # noqa: BLE001
                detail = ""
            raise SystemExit(f"{method} {path} failed: HTTP {exc.code} {detail}") from exc

    def json(self, method: str, path: str, body: dict | None = None) -> dict:
        with self.request(method, path, body) as response:
            return json.loads(response.read())

    def login(self, username: str, password: str) -> None:
        self.token = self.json("POST", "/api/v2/auth/login", {"username": username, "password": password, "device_label": "restore-tool"})["token"]


def safe_name(name: str) -> str:
    name = name.replace("\\", "/").split("/")[-1].strip().lstrip(".") or "file"
    return "".join(ch for ch in name if ch.isprintable())[:200]


def restore(client: Client, keys: VaultKeys, out_dir: Path, collection: str | None, include_thumbnails: bool = False) -> tuple[int, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    vault = client.json("GET", "/api/v2/vault")
    if vault["fingerprint"] != keys.fingerprint:
        raise SystemExit("this recovery key does not belong to the vault on the server")
    restored = failed = 0
    cursor = None
    while True:
        query = {"limit": "200"}
        if cursor:
            query["cursor"] = cursor
        if collection:
            query["collection"] = collection
        page = client.json("GET", "/api/v2/items?" + urllib.parse.urlencode(query))
        for item in page["items"]:
            try:
                manifest = json.loads(decrypt_bytes(base64.b64decode(item["manifest"]), keys.file_wrap, bytes.fromhex(item["item_id"])))
                item_dir = out_dir / item["collection"]
                item_dir.mkdir(exist_ok=True)
                for resource in manifest["resources"]:
                    if resource["role"] == "thumbnail" and not include_thumbnails:
                        continue
                    name = safe_name(resource.get("filename") or resource["object_id"])
                    target = item_dir / name
                    if target.exists():
                        target = item_dir / f"{item['item_id'][:8]}-{name}"
                    with client.request("GET", f"/api/v2/objects/{resource['object_id']}") as response, \
                         tempfile.NamedTemporaryFile(dir=item_dir, delete=False) as temp:
                        try:
                            sha = decrypt_stream(response, temp, keys.file_wrap, bytes.fromhex(resource["object_id"]))
                        except WZCEError:
                            os.unlink(temp.name)
                            raise
                    if sha != resource["sha256"]:
                        os.unlink(temp.name)
                        raise WZCEError(f"{name}: SHA-256 mismatch after decryption")
                    os.replace(temp.name, target)
                    log.info("restored %s", target)
                restored += 1
            except (WZCEError, KeyError, ValueError) as exc:
                failed += 1
                log.error("item %s failed: %s", item["item_id"], exc)
        cursor = page.get("next_cursor")
        if not cursor:
            break
    return restored, failed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", required=True)
    parser.add_argument("--username")
    parser.add_argument("--api-key-stdin", action="store_true", help="read an API key from stdin instead of logging in")
    parser.add_argument("--recovery-key-stdin", action="store_true")
    parser.add_argument("--collection", help="restore only this backup directory")
    parser.add_argument("--out", required=True)
    parser.add_argument("--include-thumbnails", action="store_true")
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING, format="%(levelname)s %(message)s")

    client = Client(args.server)
    if args.api_key_stdin:
        client.token = sys.stdin.readline().strip()
    else:
        if not args.username:
            parser.error("--username is required unless --api-key-stdin is used")
        client.login(args.username, getpass.getpass("Server password: "))
    recovery_text = sys.stdin.readline() if args.recovery_key_stdin else getpass.getpass("Recovery key: ")
    try:
        keys = VaultKeys(parse_recovery_key(recovery_text))
    except WZCEError as exc:
        raise SystemExit(f"recovery key error: {exc}") from exc
    restored, failed = restore(client, keys, Path(args.out), args.collection, args.include_thumbnails)
    print(f"restored {restored} item(s), {failed} failed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
