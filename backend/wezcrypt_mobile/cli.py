"""Operations CLI: `python -m wezcrypt_mobile <command>`."""

from __future__ import annotations

import argparse
import base64
import json
import logging
import os
import secrets
import sys
import time
from pathlib import Path

from .config import ConfigError, MobileSettings

logger = logging.getLogger("wezcrypt_mobile.cli")


def _configure_logging(verbose: bool, debug: bool) -> None:
    level = logging.DEBUG if debug else logging.INFO if verbose else logging.WARNING
    logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def _write_secret(path: Path, content: str, force: bool) -> None:
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file {path} (use --force after making a backup)")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.chmod(path, 0o600)


def cmd_generate_key(args: argparse.Namespace) -> int:
    key = base64.b64encode(secrets.token_bytes(32)).decode()
    _write_secret(Path(args.path), f"{args.key_id}:{key}\n", args.force)
    print(f"wrote key id {args.key_id} to {args.path} (mode 600). Back this file up offline: losing it makes WZC2 objects unrecoverable.")
    return 0


def cmd_generate_secret(args: argparse.Namespace) -> int:
    _write_secret(Path(args.path), secrets.token_urlsafe(48) + "\n", args.force)
    print(f"wrote internal secret to {args.path} (mode 600)")
    return 0


def _context():
    from .app_factory import MobileContext

    return MobileContext.build(MobileSettings.from_env())


def cmd_migrate(_: argparse.Namespace) -> int:
    from .db import Database

    settings = MobileSettings.from_env()
    settings.ensure_directories()
    applied = Database(settings.db_path).migrate()
    print("applied: " + (", ".join(applied) if applied else "nothing (up to date)"))
    return 0


def cmd_backup(args: argparse.Namespace) -> int:
    context = _context()
    destination = Path(args.destination)
    if destination.is_dir():
        destination = destination / f"mobile-{time.strftime('%Y%m%d-%H%M%S')}.sqlite3"
    if destination.exists():
        raise SystemExit(f"{destination} already exists")
    context.db.backup(destination)
    print(f"database backup written to {destination}")
    return 0


def cmd_approve(args: argparse.Namespace) -> int:
    from .bot_integration import approve_in_process

    result = approve_in_process(_context(), args.code, args.telegram_user_id)
    print(result.message)
    return 0 if result.ok else 1


def cmd_devices(args: argparse.Namespace) -> int:
    devices = _context().auth.list_devices_admin(args.telegram_user_id)
    print(json.dumps(devices, indent=2))
    return 0


def cmd_revoke(args: argparse.Namespace) -> int:
    ok = _context().auth.revoke_device_admin(args.device_id)
    print("revoked" if ok else "device not found or already revoked")
    return 0 if ok else 1


def cmd_purge(_: argparse.Namespace) -> int:
    context = _context()
    parts = context.uploads.purge()
    cached = context.legacy.purge_cache()
    print(f"removed {parts} expired upload parts and {cached} legacy cache files")
    return 0


def cmd_import_legacy(args: argparse.Namespace) -> int:
    context = _context()
    entries = list(context.legacy.list_files(args.telegram_user_id))
    if args.dry_run:
        print(f"{len(entries)} legacy files would be indexed (read-only references, nothing is copied or modified)")
        return 0
    imported, skipped = context.media.import_legacy(args.telegram_user_id, entries)
    print(f"indexed {imported} legacy files, skipped {skipped} already present")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wezcrypt_mobile", description="WezCrypt native-app API operations")
    parser.add_argument("-v", "--verbose", action="store_true", help="info logging")
    parser.add_argument("--debug", action="store_true", help="debug logging (never prints secrets)")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("generate-key", help="create a master keyring file")
    p.add_argument("path")
    p.add_argument("--key-id", type=int, default=1)
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_generate_key)

    p = sub.add_parser("generate-secret", help="create the bot<->API internal secret file")
    p.add_argument("path")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_generate_secret)

    sub.add_parser("migrate", help="apply database migrations").set_defaults(func=cmd_migrate)

    p = sub.add_parser("backup", help="online backup of the mobile database")
    p.add_argument("destination")
    p.set_defaults(func=cmd_backup)

    p = sub.add_parser("approve", help="approve a pairing code manually")
    p.add_argument("code")
    p.add_argument("--telegram-user-id", type=int, required=True)
    p.set_defaults(func=cmd_approve)

    p = sub.add_parser("devices", help="list devices for a Telegram user")
    p.add_argument("--telegram-user-id", type=int, required=True)
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("revoke", help="revoke a device")
    p.add_argument("device_id")
    p.set_defaults(func=cmd_revoke)

    sub.add_parser("purge", help="remove expired upload parts and stale legacy cache").set_defaults(func=cmd_purge)

    p = sub.add_parser("import-legacy", help="index existing WZC1 files as read-only library entries")
    p.add_argument("--telegram-user-id", type=int, required=True)
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_import_legacy)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    _configure_logging(args.verbose, args.debug)
    try:
        return int(args.func(args))
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
