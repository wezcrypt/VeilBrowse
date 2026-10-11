"""Encrypted object storage: chunked uploads, objects, items and vault fingerprint.

Every byte stored here was encrypted on the iPhone. The server validates
structure (sizes, SHA-256 of ciphertext, ownership) but can never read content,
filenames or metadata.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import os
import re
import shutil
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

from .auth import Principal
from .config import COLLECTION_RE, Settings
from .db import Database
from .errors import APIError, bad_request, conflict, not_found, too_large

logger = logging.getLogger("wezcrypt_backup.service")

HEX32 = re.compile(r"^[0-9a-f]{32}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
ITEM_KINDS = {"photo", "video", "livePhoto", "file"}
SERVER_VERSION = "2.0.0"


def check_hex32(value: str, what: str) -> str:
    if not HEX32.match(value):
        raise bad_request("invalid_id", f"{what} must be 32 lowercase hex characters")
    return value


def check_collection(value: str) -> str:
    if not COLLECTION_RE.match(value) or value in {".", ".."}:
        raise bad_request("invalid_collection", "Backup directory must be 1-64 chars: letters, digits, _ . -")
    return value


@dataclass(frozen=True)
class ObjectSource:
    path: Path
    size: int
    sha256: str


class BackupService:
    def __init__(self, db: Database, settings: Settings, clock: Callable[[], float] = time.time) -> None:
        self.db = db
        self.settings = settings
        self.clock = clock
        self.root = settings.storage_root.resolve()
        self._locks: dict[str, threading.Lock] = {}
        self._guard = threading.Lock()

    def _now(self) -> int:
        return int(self.clock())

    def _lock(self, key: str) -> threading.Lock:
        with self._guard:
            return self._locks.setdefault(key, threading.Lock())

    # --------------------------------------------------------------- paths

    def _inside_root(self, path: Path) -> Path:
        resolved = path.resolve()
        if resolved != self.root and self.root not in resolved.parents:
            raise APIError(500, "path_violation", "Refusing to access a path outside the storage root")
        return resolved

    def object_path(self, username: str, collection: str, object_id: str) -> Path:
        check_hex32(object_id, "object_id")
        check_collection(collection)
        return self._inside_root(self.root / username / collection / "objects" / object_id[:2] / f"{object_id}.wzce")

    def upload_dir(self, upload_id: str) -> Path:
        check_hex32(upload_id, "upload_id")
        return self._inside_root(self.settings.upload_dir / upload_id)

    def chunk_path(self, upload_id: str, index: int) -> Path:
        return self.upload_dir(upload_id) / f"{index:07d}.chunk"

    # ------------------------------------------------------------- account

    def used_bytes(self, conn, user_id: int) -> int:
        stored = conn.execute("SELECT COALESCE(SUM(size_bytes),0) FROM objects WHERE user_id = ?", (user_id,)).fetchone()[0]
        pending = conn.execute(
            "SELECT COALESCE(SUM(size_bytes),0) FROM uploads WHERE user_id = ? AND status = 'active'", (user_id,)
        ).fetchone()[0]
        return int(stored), int(pending)

    def account(self, principal: Principal) -> dict:
        disk = shutil.disk_usage(self.root)
        with self.db.read() as conn:
            user = conn.execute("SELECT quota_bytes FROM users WHERE id = ?", (principal.user_id,)).fetchone()
            stored, pending = self.used_bytes(conn, principal.user_id)
            items = conn.execute("SELECT COUNT(*) FROM items WHERE user_id = ?", (principal.user_id,)).fetchone()[0]
            vault = conn.execute("SELECT fingerprint FROM vaults WHERE user_id = ?", (principal.user_id,)).fetchone()
        return {
            "username": principal.username,
            "credential": principal.token_kind,
            "server_version": SERVER_VERSION,
            "stored_bytes": stored,
            "pending_bytes": pending,
            "item_count": items,
            "quota_bytes": user["quota_bytes"],
            "disk_free_bytes": max(disk.free - self.settings.min_free_bytes, 0),
            "vault_configured": vault is not None,
            "limits": {
                "max_object_size": self.settings.max_object_size,
                "max_chunk_size": self.settings.max_chunk_size,
                "max_chunks_per_object": self.settings.max_chunks_per_object,
                "manifest_max_bytes": self.settings.manifest_max_bytes,
            },
        }

    # --------------------------------------------------------------- vault

    def get_vault(self, principal: Principal) -> dict:
        with self.db.read() as conn:
            row = conn.execute("SELECT fingerprint, format, created_at FROM vaults WHERE user_id = ?", (principal.user_id,)).fetchone()
        if row is None:
            raise not_found("vault_not_configured", "No encryption vault is registered for this account yet")
        return dict(row)

    def put_vault(self, principal: Principal, fingerprint: str, fmt: str) -> dict:
        if not HEX64.match(fingerprint):
            raise bad_request("invalid_fingerprint", "fingerprint must be 64 hex characters")
        with self.db.tx() as conn:
            row = conn.execute("SELECT fingerprint, format, created_at FROM vaults WHERE user_id = ?", (principal.user_id,)).fetchone()
            if row is not None:
                if row["fingerprint"] != fingerprint:
                    raise conflict("vault_mismatch", "This account already uses a different recovery key. Import that key instead.")
                return dict(row)
            conn.execute(
                "INSERT INTO vaults(user_id, fingerprint, format, created_at) VALUES (?,?,?,?)",
                (principal.user_id, fingerprint, fmt, self._now()),
            )
            return {"fingerprint": fingerprint, "format": fmt, "created_at": self._now()}

    # ------------------------------------------------------------- uploads

    def _upload_dict(self, conn, row) -> dict:
        chunks = conn.execute("SELECT idx, sha256 FROM upload_chunks WHERE upload_id = ? ORDER BY idx", (row["id"],)).fetchall()
        return {
            "upload_id": row["id"],
            "object_id": row["object_id"],
            "collection": row["collection"],
            "size_bytes": row["size_bytes"],
            "chunk_size": row["chunk_size"],
            "chunk_count": row["chunk_count"],
            "status": row["status"],
            "received": [{"index": c["idx"], "sha256": c["sha256"]} for c in chunks],
            "expires_at": row["expires_at"],
        }

    def create_upload(self, principal: Principal, *, object_id: str, collection: str, size_bytes: int, chunk_size: int, chunk_count: int, sha256: str) -> dict:
        check_hex32(object_id, "object_id")
        check_collection(collection)
        if not HEX64.match(sha256):
            raise bad_request("invalid_sha256", "sha256 must be 64 hex characters")
        if size_bytes <= 0 or size_bytes > self.settings.max_object_size:
            raise too_large(f"Objects must be between 1 byte and {self.settings.max_object_size} bytes")
        if chunk_size <= 0 or chunk_size > self.settings.max_chunk_size:
            raise bad_request("invalid_chunk_size", f"chunk_size must be between 1 and {self.settings.max_chunk_size}")
        expected_chunks = (size_bytes + chunk_size - 1) // chunk_size
        if chunk_count != expected_chunks or chunk_count > self.settings.max_chunks_per_object:
            raise bad_request("invalid_chunk_count", f"chunk_count must be {expected_chunks} for this size and chunk_size")
        now = self._now()
        with self.db.tx() as conn:
            existing_object = conn.execute(
                "SELECT sha256, size_bytes FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id)
            ).fetchone()
            if existing_object is not None:
                if existing_object["sha256"] == sha256 and existing_object["size_bytes"] == size_bytes:
                    return {"status": "completed", "object_id": object_id, "size_bytes": size_bytes, "sha256": sha256}
                raise conflict("object_exists", "An object with this id already exists with different content")
            row = conn.execute(
                "SELECT * FROM uploads WHERE user_id = ? AND object_id = ? AND status = 'active'", (principal.user_id, object_id)
            ).fetchone()
            if row is not None:
                same = (row["size_bytes"], row["chunk_size"], row["chunk_count"], row["sha256"], row["collection"]) == (
                    size_bytes, chunk_size, chunk_count, sha256, collection)
                if not same:
                    raise conflict("upload_mismatch", "An active upload for this object has different parameters")
                conn.execute("UPDATE uploads SET expires_at = ?, updated_at = ? WHERE id = ?", (now + self.settings.upload_ttl, now, row["id"]))
                return {"status": "active", **self._upload_dict(conn, row)}

            active = conn.execute("SELECT COUNT(*) FROM uploads WHERE user_id = ? AND status = 'active'", (principal.user_id,)).fetchone()[0]
            if active >= self.settings.max_active_uploads_per_user:
                raise APIError(429, "too_many_uploads", "Too many concurrent uploads")
            quota = conn.execute("SELECT quota_bytes FROM users WHERE id = ?", (principal.user_id,)).fetchone()["quota_bytes"]
            stored, pending = self.used_bytes(conn, principal.user_id)
            if quota is not None and stored + pending + size_bytes > quota:
                raise APIError(507, "quota_exceeded", "Your storage quota is exhausted")
            free = shutil.disk_usage(self.root).free
            if free - size_bytes < self.settings.min_free_bytes:
                raise APIError(507, "insufficient_storage", "The server does not have enough free space")

            upload_id = os.urandom(16).hex()
            conn.execute(
                """INSERT INTO uploads(id, user_id, object_id, collection, size_bytes, chunk_size, chunk_count, sha256, status,
                       created_at, updated_at, expires_at) VALUES (?,?,?,?,?,?,?,?, 'active', ?,?,?)""",
                (upload_id, principal.user_id, object_id, collection, size_bytes, chunk_size, chunk_count, sha256,
                 now, now, now + self.settings.upload_ttl),
            )
            self.upload_dir(upload_id).mkdir(mode=0o700, parents=True, exist_ok=False)
            row = conn.execute("SELECT * FROM uploads WHERE id = ?", (upload_id,)).fetchone()
            return {"status": "active", **self._upload_dict(conn, row)}

    def _active_upload(self, conn, principal: Principal, upload_id: str):
        check_hex32(upload_id, "upload_id")
        row = conn.execute("SELECT * FROM uploads WHERE id = ? AND user_id = ?", (upload_id, principal.user_id)).fetchone()
        if row is None:
            raise not_found("upload_not_found", "Upload not found")
        if row["status"] == "completed":
            raise conflict("upload_completed", "Upload already completed", extra={"object_id": row["object_id"]})
        if row["status"] != "active" or row["expires_at"] <= self._now():
            raise APIError(410, "upload_expired", "Upload session expired; start a new upload")
        return row

    def upload_status(self, principal: Principal, upload_id: str) -> dict:
        check_hex32(upload_id, "upload_id")
        with self.db.read() as conn:
            row = conn.execute("SELECT * FROM uploads WHERE id = ? AND user_id = ?", (upload_id, principal.user_id)).fetchone()
            if row is None:
                raise not_found("upload_not_found", "Upload not found")
            return self._upload_dict(conn, row)

    def expected_chunk_size(self, row, index: int) -> int:
        if index < 0 or index >= row["chunk_count"]:
            raise bad_request("invalid_chunk_index", f"chunk index must be between 0 and {row['chunk_count'] - 1}")
        if index < row["chunk_count"] - 1:
            return row["chunk_size"]
        return row["size_bytes"] - row["chunk_size"] * (row["chunk_count"] - 1)

    def begin_chunk(self, principal: Principal, upload_id: str, index: int) -> tuple[int, dict | None]:
        """Validates a chunk request; returns (expected size, existing chunk or None)."""
        with self.db.read() as conn:
            row = self._active_upload(conn, principal, upload_id)
            expected = self.expected_chunk_size(row, index)
            existing = conn.execute("SELECT sha256 FROM upload_chunks WHERE upload_id = ? AND idx = ?", (upload_id, index)).fetchone()
        return expected, (dict(existing) if existing else None)

    def store_chunk(self, principal: Principal, upload_id: str, index: int, temp_path: Path, size: int, sha256: str) -> dict:
        """Commits a fully received, hash-verified chunk file."""
        lock = self._lock(f"{upload_id}:{index}")
        with lock:
            with self.db.tx() as conn:
                row = self._active_upload(conn, principal, upload_id)
                expected = self.expected_chunk_size(row, index)
                if size != expected:
                    raise bad_request("chunk_size_mismatch", f"chunk {index} must be {expected} bytes")
                existing = conn.execute("SELECT sha256 FROM upload_chunks WHERE upload_id = ? AND idx = ?", (upload_id, index)).fetchone()
                if existing is not None:
                    temp_path.unlink(missing_ok=True)
                    if existing["sha256"] != sha256:
                        raise conflict("chunk_conflict", "This chunk was already received with different content")
                    return {"index": index, "sha256": sha256, "status": "already_received"}
                os.replace(temp_path, self.chunk_path(upload_id, index))
                conn.execute(
                    "INSERT INTO upload_chunks(upload_id, idx, size_bytes, sha256, received_at) VALUES (?,?,?,?,?)",
                    (upload_id, index, size, sha256, self._now()),
                )
                conn.execute("UPDATE uploads SET updated_at = ? WHERE id = ?", (self._now(), upload_id))
        return {"index": index, "sha256": sha256, "status": "received"}

    def complete_upload(self, principal: Principal, upload_id: str) -> dict:
        lock = self._lock(f"complete:{upload_id}")
        if not lock.acquire(blocking=False):
            raise conflict("upload_busy", "Upload is already being completed")
        try:
            with self.db.read() as conn:
                row = self._active_upload(conn, principal, upload_id)
                received = conn.execute("SELECT idx, size_bytes FROM upload_chunks WHERE upload_id = ? ORDER BY idx", (upload_id,)).fetchall()
            missing = sorted(set(range(row["chunk_count"])) - {r["idx"] for r in received})
            if missing:
                raise conflict("upload_incomplete", "Some chunks have not been received", extra={"missing": missing[:1000]})
            target = self.object_path(principal.username, row["collection"], row["object_id"])
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            temp = target.with_name(target.name + f".{upload_id}.tmp")
            digest = hashlib.sha256()
            total = 0
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            try:
                with os.fdopen(fd, "wb") as out:
                    for index in range(row["chunk_count"]):
                        with self.chunk_path(upload_id, index).open("rb") as chunk:
                            while block := chunk.read(1024 * 1024):
                                digest.update(block)
                                total += len(block)
                                out.write(block)
                    out.flush()
                    os.fsync(out.fileno())
                if total != row["size_bytes"] or digest.hexdigest() != row["sha256"]:
                    temp.unlink(missing_ok=True)
                    self._discard_chunks(upload_id)
                    raise APIError(422, "object_hash_mismatch", "Assembled object does not match the declared SHA-256; upload again")
                os.replace(temp, target)
            except BaseException:
                temp.unlink(missing_ok=True)
                raise
            now = self._now()
            with self.db.tx() as conn:
                conn.execute(
                    "INSERT OR REPLACE INTO objects(id, user_id, collection, size_bytes, sha256, created_at) VALUES (?,?,?,?,?,?)",
                    (row["object_id"], principal.user_id, row["collection"], total, row["sha256"], now),
                )
                conn.execute("UPDATE uploads SET status = 'completed', updated_at = ? WHERE id = ?", (now, upload_id))
                conn.execute("DELETE FROM upload_chunks WHERE upload_id = ?", (upload_id,))
            shutil.rmtree(self.upload_dir(upload_id), ignore_errors=True)
            return {"status": "completed", "object_id": row["object_id"], "size_bytes": total, "sha256": row["sha256"]}
        finally:
            lock.release()

    def _discard_chunks(self, upload_id: str) -> None:
        with self.db.tx() as conn:
            conn.execute("DELETE FROM upload_chunks WHERE upload_id = ?", (upload_id,))
        for path in self.upload_dir(upload_id).glob("*.chunk"):
            path.unlink(missing_ok=True)

    def cancel_upload(self, principal: Principal, upload_id: str) -> None:
        with self.db.tx() as conn:
            self._active_upload(conn, principal, upload_id)
            conn.execute("UPDATE uploads SET status = 'cancelled', updated_at = ? WHERE id = ?", (self._now(), upload_id))
            conn.execute("DELETE FROM upload_chunks WHERE upload_id = ?", (upload_id,))
        shutil.rmtree(self.upload_dir(upload_id), ignore_errors=True)

    def purge(self) -> int:
        now = self._now()
        with self.db.tx() as conn:
            rows = conn.execute("SELECT id FROM uploads WHERE status = 'active' AND expires_at <= ?", (now,)).fetchall()
            conn.execute("UPDATE uploads SET status = 'cancelled', updated_at = ? WHERE status = 'active' AND expires_at <= ?", (now, now))
            conn.execute("DELETE FROM upload_chunks WHERE upload_id IN (SELECT id FROM uploads WHERE status != 'active')")
            conn.execute("DELETE FROM uploads WHERE status != 'active' AND updated_at < ?", (now - 30 * 86400,))
        for row in rows:
            shutil.rmtree(self.upload_dir(row["id"]), ignore_errors=True)
        for path in self.settings.upload_dir.iterdir() if self.settings.upload_dir.exists() else []:
            if path.is_dir() and HEX32.match(path.name):
                with self.db.read() as conn:
                    active = conn.execute("SELECT 1 FROM uploads WHERE id = ? AND status = 'active'", (path.name,)).fetchone()
                if active is None:
                    shutil.rmtree(path, ignore_errors=True)
        return len(rows)

    # ------------------------------------------------------------- objects

    def object_source(self, principal: Principal, object_id: str) -> ObjectSource:
        check_hex32(object_id, "object_id")
        with self.db.read() as conn:
            row = conn.execute("SELECT collection, size_bytes, sha256 FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id)).fetchone()
        if row is None:
            raise not_found("object_not_found", "Object not found")
        path = self.object_path(principal.username, row["collection"], object_id)
        if not path.exists():
            raise APIError(500, "object_missing", "Object file is missing on the server")
        return ObjectSource(path=path, size=row["size_bytes"], sha256=row["sha256"])

    @staticmethod
    def iter_file(path: Path, start: int, end_inclusive: int) -> Iterator[bytes]:
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = end_inclusive - start + 1
            while remaining > 0:
                block = handle.read(min(1024 * 1024, remaining))
                if not block:
                    break
                remaining -= len(block)
                yield block

    def delete_object(self, principal: Principal, object_id: str) -> None:
        check_hex32(object_id, "object_id")
        with self.db.tx() as conn:
            row = conn.execute("SELECT collection FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id)).fetchone()
            if row is None:
                raise not_found("object_not_found", "Object not found")
            if conn.execute("SELECT 1 FROM item_objects WHERE user_id = ? AND object_id = ?", (principal.user_id, object_id)).fetchone():
                raise conflict("object_in_use", "Object belongs to an item; delete the item instead")
            conn.execute("DELETE FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id))
        self.object_path(principal.username, row["collection"], object_id).unlink(missing_ok=True)

    # --------------------------------------------------------------- items

    @staticmethod
    def _item_dict(row, object_ids: list[str]) -> dict:
        return {
            "item_id": row["id"],
            "collection": row["collection"],
            "content_tag": row["content_tag"],
            "kind": row["kind"],
            "manifest": base64.b64encode(row["manifest"]).decode(),
            "total_bytes": row["total_bytes"],
            "object_ids": object_ids,
            "created_at": row["created_at"],
        }

    def _objects_for(self, conn, user_id: int, item_id: str) -> list[str]:
        return [r["object_id"] for r in conn.execute(
            "SELECT object_id FROM item_objects WHERE user_id = ? AND item_id = ? ORDER BY object_id", (user_id, item_id))]

    def create_item(self, principal: Principal, *, item_id: str, collection: str, content_tag: str, kind: str, manifest_b64: str, object_ids: list[str]) -> tuple[int, dict]:
        check_hex32(item_id, "item_id")
        check_collection(collection)
        if not HEX64.match(content_tag):
            raise bad_request("invalid_content_tag", "content_tag must be 64 hex characters")
        if kind not in ITEM_KINDS:
            raise bad_request("invalid_kind", "kind must be photo, video, livePhoto or file")
        try:
            manifest = base64.b64decode(manifest_b64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise bad_request("invalid_manifest", "manifest must be base64") from exc
        if not manifest or len(manifest) > self.settings.manifest_max_bytes:
            raise too_large("Encrypted manifest is empty or too large")
        if manifest[:4] != b"WZCE":
            raise bad_request("invalid_manifest", "manifest must be a WZCE encrypted blob")
        ids = sorted(set(object_ids))
        if not ids or len(ids) > 64:
            raise bad_request("invalid_objects", "An item needs 1-64 objects")
        for object_id in ids:
            check_hex32(object_id, "object_id")
        with self.db.tx() as conn:
            same = conn.execute("SELECT * FROM items WHERE user_id = ? AND id = ?", (principal.user_id, item_id)).fetchone()
            if same is not None:
                if same["content_tag"] != content_tag:
                    raise conflict("item_exists", "Item id already used for different content")
                return 200, self._item_dict(same, self._objects_for(conn, principal.user_id, item_id))
            dup = conn.execute("SELECT * FROM items WHERE user_id = ? AND content_tag = ?", (principal.user_id, content_tag)).fetchone()
            if dup is not None:
                raise conflict("duplicate", "This content is already backed up", extra={"item_id": dup["id"]})
            total = 0
            for object_id in ids:
                obj = conn.execute("SELECT size_bytes, collection FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id)).fetchone()
                if obj is None:
                    raise bad_request("object_not_found", f"Object {object_id} has not been uploaded")
                total += obj["size_bytes"]
            now = self._now()
            conn.execute(
                "INSERT INTO items(id, user_id, collection, content_tag, kind, manifest, total_bytes, created_at) VALUES (?,?,?,?,?,?,?,?)",
                (item_id, principal.user_id, collection, content_tag, kind, manifest, total, now),
            )
            for object_id in ids:
                conn.execute("INSERT INTO item_objects(user_id, item_id, object_id) VALUES (?,?,?)", (principal.user_id, item_id, object_id))
            row = conn.execute("SELECT * FROM items WHERE user_id = ? AND id = ?", (principal.user_id, item_id)).fetchone()
            return 201, self._item_dict(row, ids)

    def check_tags(self, principal: Principal, tags: list[str]) -> dict[str, str]:
        found: dict[str, str] = {}
        with self.db.read() as conn:
            for start in range(0, len(tags), 400):
                batch = [t for t in tags[start : start + 400] if HEX64.match(t)]
                if not batch:
                    continue
                placeholders = ",".join("?" for _ in batch)
                for row in conn.execute(
                    f"SELECT content_tag, id FROM items WHERE user_id = ? AND content_tag IN ({placeholders})", (principal.user_id, *batch)
                ):
                    found[row["content_tag"]] = row["id"]
        return found

    def list_items(self, principal: Principal, *, collection: str | None, kind: str | None, cursor: str | None, limit: int) -> dict:
        limit = max(1, min(limit, self.settings.page_max))
        where = ["user_id = ?"]
        params: list = [principal.user_id]
        if collection:
            where.append("collection = ?")
            params.append(check_collection(collection))
        if kind:
            if kind not in ITEM_KINDS:
                raise bad_request("invalid_kind", "unknown kind")
            where.append("kind = ?")
            params.append(kind)
        if cursor:
            try:
                created, item_id = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
                if not isinstance(created, int):
                    raise ValueError
                check_hex32(str(item_id), "cursor")
            except (ValueError, TypeError, binascii.Error, json.JSONDecodeError, APIError) as exc:
                raise bad_request("invalid_cursor", "cursor is invalid") from exc
            where.append("(created_at < ? OR (created_at = ? AND id < ?))")
            params += [created, created, item_id]
        params.append(limit + 1)
        with self.db.read() as conn:
            rows = conn.execute(
                f"SELECT * FROM items WHERE {' AND '.join(where)} ORDER BY created_at DESC, id DESC LIMIT ?", params
            ).fetchall()
            more = len(rows) > limit
            rows = rows[:limit]
            items = [self._item_dict(r, self._objects_for(conn, principal.user_id, r["id"])) for r in rows]
        next_cursor = None
        if more and rows:
            next_cursor = base64.urlsafe_b64encode(json.dumps([rows[-1]["created_at"], rows[-1]["id"]]).encode()).decode().rstrip("=")
        return {"items": items, "next_cursor": next_cursor}

    def get_item(self, principal: Principal, item_id: str) -> dict:
        check_hex32(item_id, "item_id")
        with self.db.read() as conn:
            row = conn.execute("SELECT * FROM items WHERE user_id = ? AND id = ?", (principal.user_id, item_id)).fetchone()
            if row is None:
                raise not_found("item_not_found", "Item not found")
            return self._item_dict(row, self._objects_for(conn, principal.user_id, item_id))

    def delete_item(self, principal: Principal, item_id: str) -> int:
        check_hex32(item_id, "item_id")
        removed: list[tuple[str, str]] = []
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM items WHERE user_id = ? AND id = ?", (principal.user_id, item_id)).fetchone()
            if row is None:
                raise not_found("item_not_found", "Item not found")
            object_ids = self._objects_for(conn, principal.user_id, item_id)
            conn.execute("DELETE FROM item_objects WHERE user_id = ? AND item_id = ?", (principal.user_id, item_id))
            conn.execute("DELETE FROM items WHERE user_id = ? AND id = ?", (principal.user_id, item_id))
            for object_id in object_ids:
                if conn.execute("SELECT 1 FROM item_objects WHERE user_id = ? AND object_id = ?", (principal.user_id, object_id)).fetchone():
                    continue
                obj = conn.execute("SELECT collection FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id)).fetchone()
                if obj is not None:
                    conn.execute("DELETE FROM objects WHERE user_id = ? AND id = ?", (principal.user_id, object_id))
                    removed.append((obj["collection"], object_id))
        for collection, object_id in removed:
            self.object_path(principal.username, collection, object_id).unlink(missing_ok=True)
        return len(removed)
