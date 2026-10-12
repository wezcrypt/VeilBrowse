"""Administration CLI: `python -m wezcrypt_backup <command>`.

Passwords are never accepted as command-line arguments (they would leak into
shell history and `ps`). They are read interactively or from stdin.
"""

from __future__ import annotations

import argparse
import getpass
import json
import logging
import os
import sys
import time
from pathlib import Path

from .config import ConfigError, Settings, generate_secret_text


def _read_password(from_stdin: bool) -> str:
    if from_stdin:
        password = sys.stdin.readline().rstrip("\n")
    else:
        password = getpass.getpass("New password: ")
        if getpass.getpass("Repeat password: ") != password:
            raise SystemExit("passwords do not match")
    return password


def _context():
    from .app_factory import Context

    return Context.build(Settings.from_env())


def cmd_generate_pepper(args) -> int:
    path = Path(args.path)
    if path.exists() and not args.force:
        raise SystemExit(f"{path} exists; refusing to overwrite (rotating it signs everyone out). Use --force after a backup.")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(generate_secret_text() + "\n")
    os.chmod(path, 0o600)
    print(f"wrote token pepper to {path} (mode 600)")
    return 0


def cmd_migrate(_args) -> int:
    from .db import Database

    settings = Settings.from_env()
    settings.ensure_directories()
    applied = Database(settings.db_path).migrate()
    print("applied: " + (", ".join(applied) if applied else "nothing (up to date)"))
    return 0


def cmd_create_user(args) -> int:
    ctx = _context()
    password = None if args.no_password else _read_password(args.password_stdin)
    quota = int(args.quota_gb * 1024**3) if args.quota_gb else None
    try:
        ctx.auth.create_user(args.username, password, quota)
    except ValueError as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(f"created user {args.username}")
    return 0


def cmd_set_password(args) -> int:
    ctx = _context()
    try:
        ctx.auth.set_password(args.username, _read_password(args.password_stdin))
    except ValueError as exc:
        raise SystemExit(f"error: {exc}") from exc
    print(f"password updated for {args.username}; existing sessions were signed out")
    return 0


def cmd_create_api_key(args) -> int:
    ctx = _context()
    try:
        key = ctx.auth.create_api_key(args.username, args.label)
    except ValueError as exc:
        raise SystemExit(f"error: {exc}") from exc
    print("API key (shown once; store it in a password manager and paste it into the app):")
    print(key)
    return 0


def cmd_revoke_api_keys(args) -> int:
    count = _context().auth.revoke_api_keys(args.username, args.label)
    print(f"revoked {count} API key(s)")
    return 0


def cmd_disable(args) -> int:
    _context().auth.set_disabled(args.username, not args.enable)
    print(("enabled " if args.enable else "disabled ") + args.username)
    return 0


def cmd_quota(args) -> int:
    quota = int(args.gb * 1024**3) if args.gb else None
    _context().auth.set_quota(args.username, quota)
    print("quota updated")
    return 0


def cmd_users(_args) -> int:
    print(json.dumps(_context().auth.list_users(), indent=2))
    return 0


def cmd_stats(_args) -> int:
    """Upload-session health per user (counts and sizes only)."""
    ctx = _context()
    now = int(time.time())
    with ctx.db.read() as conn:
        rows = conn.execute(
            """SELECT u.username,
                      (SELECT COUNT(*) FROM uploads s WHERE s.user_id = u.id AND s.status = 'active') AS open_sessions,
                      (SELECT COUNT(*) FROM uploads s WHERE s.user_id = u.id AND s.status = 'active' AND s.updated_at < ?) AS idle_sessions,
                      (SELECT COUNT(*) FROM objects o WHERE o.user_id = u.id) AS objects,
                      (SELECT COALESCE(SUM(size_bytes),0) FROM objects o WHERE o.user_id = u.id) AS stored_bytes,
                      (SELECT COUNT(*) FROM items i WHERE i.user_id = u.id) AS items
               FROM users u ORDER BY u.username""",
            (now - ctx.settings.abandoned_upload_seconds,),
        ).fetchall()
    print(json.dumps({
        "limits": {
            "max_open_upload_sessions": ctx.settings.max_active_uploads_per_user,
            "max_concurrent_chunk_requests": ctx.settings.max_inflight_chunks_per_user,
            "abandoned_upload_seconds": ctx.settings.abandoned_upload_seconds,
        },
        "users": [dict(row) for row in rows],
    }, indent=2))
    return 0


def cmd_reclaim(_args) -> int:
    """Cancels upload sessions that never received a chunk and have been idle longer
    than WZC_BACKUP_ABANDONED_UPLOAD_SECONDS. Sessions with data are never touched."""
    ctx = _context()
    now = int(time.time())
    total = 0
    with ctx.db.tx() as conn:
        for row in conn.execute("SELECT id FROM users").fetchall():
            total += len(ctx.service._reclaim_abandoned(conn, row["id"], now))
    print(f"reclaimed {total} abandoned upload session(s)")
    return 0


def cmd_purge(_args) -> int:
    print(f"expired {_context().service.purge()} stale upload(s)")
    return 0


def cmd_backup_db(args) -> int:
    ctx = _context()
    destination = Path(args.destination)
    if destination.is_dir():
        destination = destination / f"backup-db-{time.strftime('%Y%m%d-%H%M%S')}.sqlite3"
    if destination.exists():
        raise SystemExit(f"{destination} already exists")
    ctx.db.backup(destination)
    print(f"database copied to {destination}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="wezcrypt_backup", description="WezCrypt encrypted backup server administration")
    parser.add_argument("-v", "--verbose", action="store_true")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("generate-pepper", help="create the token pepper secret file")
    p.add_argument("path")
    p.add_argument("--force", action="store_true")
    p.set_defaults(func=cmd_generate_pepper)

    sub.add_parser("migrate", help="apply database migrations").set_defaults(func=cmd_migrate)

    p = sub.add_parser("create-user")
    p.add_argument("username")
    p.add_argument("--password-stdin", action="store_true", help="read the password from stdin")
    p.add_argument("--no-password", action="store_true", help="API-key-only account")
    p.add_argument("--quota-gb", type=float)
    p.set_defaults(func=cmd_create_user)

    p = sub.add_parser("set-password")
    p.add_argument("username")
    p.add_argument("--password-stdin", action="store_true")
    p.set_defaults(func=cmd_set_password)

    p = sub.add_parser("create-api-key")
    p.add_argument("username")
    p.add_argument("--label", default="iphone")
    p.set_defaults(func=cmd_create_api_key)

    p = sub.add_parser("revoke-api-keys")
    p.add_argument("username")
    p.add_argument("--label")
    p.set_defaults(func=cmd_revoke_api_keys)

    p = sub.add_parser("disable-user")
    p.add_argument("username")
    p.add_argument("--enable", action="store_true")
    p.set_defaults(func=cmd_disable)

    p = sub.add_parser("set-quota")
    p.add_argument("username")
    p.add_argument("--gb", type=float, help="omit for unlimited")
    p.set_defaults(func=cmd_quota)

    sub.add_parser("users").set_defaults(func=cmd_users)
    sub.add_parser("stats", help="upload-session health per user").set_defaults(func=cmd_stats)
    sub.add_parser("reclaim-abandoned", help="cancel empty, idle upload sessions").set_defaults(func=cmd_reclaim)
    sub.add_parser("purge", help="expire stale uploads").set_defaults(func=cmd_purge)

    p = sub.add_parser("backup-db")
    p.add_argument("destination")
    p.set_defaults(func=cmd_backup_db)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    logging.basicConfig(level=logging.INFO if args.verbose else logging.WARNING, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        return int(args.func(args))
    except ConfigError as exc:
        print(f"configuration error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
