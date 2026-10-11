"""Resumable, chunked uploads that never write plaintext to disk (WZC2 mode).

Protocol
--------
* ``POST /uploads`` declares size + SHA-256. Returns ``duplicate`` when the
  user already owns identical content, or an upload session with ``offset`` and
  ``chunk_size``.
* ``PATCH /uploads/{id}`` with ``Upload-Offset`` and
  ``Upload-Checksum: sha256 <base64>``. Every chunk except the last must be a
  multiple of ``segment_size``. Chunks are encrypted segment by segment and
  appended to the WZC2 part file immediately.
* ``POST /uploads/{id}/complete`` re-reads the encrypted part, verifies the
  whole-file SHA-256 by streaming decryption and publishes the object.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import logging
import os
import re
import tempfile
import threading
import time
import unicodedata
from collections.abc import Callable
from pathlib import Path

from .auth_service import Principal
from .config import MobileSettings
from .crypto import HEADER_SIZE, TAG_SIZE, Header, SegmentEncryptor, SegmentReader, WZC2Error, ciphertext_size
from .db import Database
from .errors import APIError, bad_request, conflict, not_found, too_large
from .legacy import LegacyBridge
from .media import MediaService
from .security import new_id
from .storage import ObjectStore

logger = logging.getLogger("wezcrypt_mobile.uploads")

_MIME_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$")


def sanitize_filename(name: str) -> str:
    name = unicodedata.normalize("NFC", name)
    name = name.replace("\\", "/").split("/")[-1]
    name = "".join(ch for ch in name if unicodedata.category(ch)[0] != "C").strip().strip(".")
    if not name:
        name = "file"
    encoded = name.encode("utf-8")[:255]
    return encoded.decode("utf-8", errors="ignore") or "file"


def validate_mime(mime_type: str, media_type: str) -> str:
    mime = mime_type.strip().lower()
    if not _MIME_RE.match(mime) or len(mime) > 127:
        raise bad_request("invalid_mime_type", "mime_type is invalid")
    if mime == "application/octet-stream":
        return mime
    expected = "image/" if media_type == "photo" else "video/"
    if not mime.startswith(expected):
        raise bad_request("invalid_mime_type", f"mime_type must start with {expected} for {media_type}")
    return mime


def parse_checksum(header: str | None) -> bytes:
    if not header:
        raise bad_request("checksum_required", "Upload-Checksum header is required")
    algorithm, _, value = header.strip().partition(" ")
    if algorithm.lower() != "sha256" or not value:
        raise bad_request("invalid_checksum", "Upload-Checksum must be 'sha256 <base64>'")
    try:
        digest = base64.b64decode(value.strip(), validate=True)
    except (binascii.Error, ValueError) as exc:
        raise bad_request("invalid_checksum", "Upload-Checksum is not valid base64") from exc
    if len(digest) != 32:
        raise bad_request("invalid_checksum", "Upload-Checksum must be a SHA-256 digest")
    return digest


class UploadService:
    def __init__(
        self,
        db: Database,
        settings: MobileSettings,
        store: ObjectStore,
        media: MediaService,
        legacy: LegacyBridge,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.db = db
        self.settings = settings
        self.store = store
        self.media = media
        self.legacy = legacy
        self.clock = clock
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()

    def _now(self) -> int:
        return int(self.clock())

    def _lock(self, upload_id: str) -> threading.Lock:
        with self._locks_guard:
            return self._locks.setdefault(upload_id, threading.Lock())

    def _release_lock_entry(self, upload_id: str) -> None:
        with self._locks_guard:
            self._locks.pop(upload_id, None)

    def _session_dict(self, row) -> dict:
        return {
            "status": "created",
            "upload_id": row["id"],
            "offset": row["upload_offset"],
            "size_bytes": row["size_bytes"],
            "chunk_size": self.settings.chunk_size,
            "segment_size": self.settings.segment_size,
            "expires_at": row["expires_at"],
        }

    def create(self, principal: Principal, body: dict) -> dict:
        size = int(body["size_bytes"])
        if size > self.settings.max_file_size:
            raise too_large(f"Files larger than {self.settings.max_file_size} bytes are not accepted")
        media_type = body["media_type"]
        mime = validate_mime(body["mime_type"], media_type)
        filename = sanitize_filename(body["filename"])
        sha256 = body["sha256"]
        now = self._now()

        existing = self.media.find_by_sha(principal.user_id, sha256)
        if existing is not None:
            return {"status": "duplicate", "media": existing}

        metadata = {
            "taken_at": body.get("taken_at"),
            "width": body.get("width"),
            "height": body.get("height"),
            "duration_ms": body.get("duration_ms"),
            "is_favorite": bool(body.get("is_favorite", False)),
            "is_screenshot": bool(body.get("is_screenshot", False)),
            "local_identifier": body.get("local_identifier"),
        }

        with self.db.tx() as conn:
            row = conn.execute(
                """SELECT * FROM mobile_uploads WHERE user_id = ? AND sha256 = ? AND status = 'active'
                   AND expires_at > ? AND size_bytes = ? ORDER BY created_at DESC LIMIT 1""",
                (principal.user_id, sha256, now, size),
            ).fetchone()
            if row is not None and self.store.part_path(row["id"]).exists():
                if row["device_id"] != principal.device_id:
                    conn.execute(
                        "UPDATE mobile_uploads SET device_id = ?, updated_at = ? WHERE id = ?",
                        (principal.device_id, now, row["id"]),
                    )
                return self._session_dict(row)

            active = conn.execute(
                "SELECT COUNT(*) FROM mobile_uploads WHERE device_id = ? AND status = 'active' AND expires_at > ?",
                (principal.device_id, now),
            ).fetchone()[0]
            if active >= self.settings.max_active_uploads_per_device:
                raise APIError(429, "too_many_uploads", "Too many concurrent upload sessions for this device")

            upload_id = new_id()
            key_id, kek = self.store.active_kek
            encryptor = SegmentEncryptor(kek, key_id, size, self.settings.segment_size)
            part = self.store.part_path(upload_id)
            fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as handle:
                handle.write(encryptor.header_bytes)
                handle.flush()
                os.fsync(handle.fileno())
            conn.execute(
                """INSERT INTO mobile_uploads(id, user_id, device_id, filename, mime_type, media_type, size_bytes, sha256,
                       upload_offset, metadata, status, created_at, updated_at, expires_at)
                   VALUES (?,?,?,?,?,?,?,?,0,?, 'active', ?, ?, ?)""",
                (upload_id, principal.user_id, principal.device_id, filename, mime, media_type, size, sha256,
                 json.dumps(metadata), now, now, now + self.settings.upload_ttl),
            )
            row = conn.execute("SELECT * FROM mobile_uploads WHERE id = ?", (upload_id,)).fetchone()
        return self._session_dict(row)

    def _get_active(self, principal: Principal, upload_id: str):
        with self.db.read() as conn:
            row = conn.execute(
                "SELECT * FROM mobile_uploads WHERE id = ? AND user_id = ?", (upload_id, principal.user_id)
            ).fetchone()
        if row is None:
            raise not_found("upload_not_found", "Upload not found")
        if row["status"] == "completed":
            raise conflict("upload_completed", "Upload already completed", extra={"media_id": row["media_id"]})
        if row["status"] != "active" or row["expires_at"] <= self._now():
            raise APIError(410, "upload_expired", "Upload session is no longer active")
        return row

    def status(self, principal: Principal, upload_id: str) -> dict:
        with self.db.read() as conn:
            row = conn.execute(
                "SELECT * FROM mobile_uploads WHERE id = ? AND user_id = ?", (upload_id, principal.user_id)
            ).fetchone()
        if row is None:
            raise not_found("upload_not_found", "Upload not found")
        result = self._session_dict(row)
        result["status"] = row["status"]
        result["media_id"] = row["media_id"]
        return result

    def append(self, principal: Principal, upload_id: str, offset: int, data: bytes, checksum: bytes) -> dict:
        lock = self._lock(upload_id)
        if not lock.acquire(blocking=False):
            raise conflict("upload_busy", "Another request is writing to this upload")
        try:
            row = self._get_active(principal, upload_id)
            current = row["upload_offset"]
            size = row["size_bytes"]
            if offset != current:
                raise conflict("offset_mismatch", "Upload-Offset does not match the server offset", extra={"offset": current})
            if not data and size > 0:
                raise bad_request("empty_chunk", "Chunk is empty")
            if len(data) > self.settings.max_chunk_bytes:
                raise too_large("Chunk exceeds the maximum chunk size")
            if offset + len(data) > size:
                raise bad_request("chunk_overflow", "Chunk extends past the declared file size")
            segment = self.settings.segment_size
            final_chunk = offset + len(data) == size
            if not final_chunk and len(data) % segment != 0:
                raise bad_request("chunk_alignment", f"Non-final chunks must be a multiple of {segment} bytes")
            if hashlib.sha256(data).digest() != checksum:
                raise bad_request("checksum_mismatch", "Chunk checksum does not match")

            part = self.store.part_path(upload_id)
            with part.open("r+b") as handle:
                header_bytes = handle.read(HEADER_SIZE)
                header = Header.unpack(header_bytes)
                encryptor = SegmentEncryptor.resume(self.store.keyring.get(header.key_id), header_bytes)
                first_index = offset // segment
                handle.seek(HEADER_SIZE + first_index * (segment + TAG_SIZE))
                handle.truncate()
                if size == 0:
                    handle.write(encryptor.encrypt_segment(0, b""))
                else:
                    view = memoryview(data)
                    for i in range(0, len(data), segment):
                        index = first_index + i // segment
                        handle.write(encryptor.encrypt_segment(index, bytes(view[i : i + segment])))
                handle.flush()
                os.fsync(handle.fileno())

            new_offset = offset + len(data)
            with self.db.tx() as conn:
                conn.execute(
                    "UPDATE mobile_uploads SET upload_offset = ?, updated_at = ? WHERE id = ? AND upload_offset = ?",
                    (new_offset, self._now(), upload_id, offset),
                )
            return {"upload_id": upload_id, "offset": new_offset, "size_bytes": size}
        except WZC2Error as exc:
            logger.error("upload %s part file is corrupt: %s", upload_id, exc)
            raise APIError(500, "upload_corrupt", "Upload state is corrupt; start a new upload") from exc
        finally:
            lock.release()

    def complete(self, principal: Principal, upload_id: str) -> dict:
        lock = self._lock(upload_id)
        if not lock.acquire(blocking=False):
            raise conflict("upload_busy", "Another request is writing to this upload")
        try:
            row = self._get_active(principal, upload_id)
            size = row["size_bytes"]
            if size == 0 and row["upload_offset"] == 0:
                self.append_empty_if_needed(upload_id)
            elif row["upload_offset"] != size:
                raise conflict("upload_incomplete", "Upload is not complete", extra={"offset": row["upload_offset"]})
            part = self.store.part_path(upload_id)
            if part.stat().st_size != ciphertext_size(size, self.settings.segment_size):
                raise APIError(500, "upload_corrupt", "Upload part has an unexpected length")
            digest = hashlib.sha256()
            with part.open("rb") as handle:
                for chunk in SegmentReader(handle, self.store.keyring).iter_all():
                    digest.update(chunk)
            if digest.hexdigest() != row["sha256"]:
                self._fail(upload_id)
                raise APIError(422, "hash_mismatch", "Uploaded content does not match the declared SHA-256")

            metadata = json.loads(row["metadata"])
            media_id = new_id()
            if self.settings.storage_format == "legacy":
                storage_kind = "legacy"
                storage_ref = self._store_legacy(principal, row, part)
                part.unlink(missing_ok=True)
            else:
                storage_kind = "wzc2"
                storage_ref = ObjectStore.new_ref(media_id)
                self.store.commit_part(upload_id, storage_ref)

            try:
                media = self.media.insert(
                    media_id=media_id,
                    user_id=principal.user_id,
                    device_id=principal.device_id,
                    filename=row["filename"],
                    mime_type=row["mime_type"],
                    media_type=row["media_type"],
                    size_bytes=size,
                    sha256=row["sha256"],
                    metadata=metadata,
                    storage_kind=storage_kind,
                    storage_ref=storage_ref,
                )
            except APIError:
                if storage_kind == "wzc2":
                    self.store.delete(storage_ref)
                raise
            with self.db.tx() as conn:
                conn.execute(
                    "UPDATE mobile_uploads SET status = 'completed', media_id = ?, updated_at = ? WHERE id = ?",
                    (media["id"], self._now(), upload_id),
                )
            return {"media": media}
        finally:
            lock.release()
            self._release_lock_entry(upload_id)

    def append_empty_if_needed(self, upload_id: str) -> None:
        part = self.store.part_path(upload_id)
        if part.stat().st_size == HEADER_SIZE:
            with part.open("r+b") as handle:
                header_bytes = handle.read(HEADER_SIZE)
                header = Header.unpack(header_bytes)
                encryptor = SegmentEncryptor.resume(self.store.keyring.get(header.key_id), header_bytes)
                handle.seek(HEADER_SIZE)
                handle.write(encryptor.encrypt_segment(0, b""))
                handle.flush()
                os.fsync(handle.fileno())

    def _store_legacy(self, principal: Principal, row, part: Path) -> str:
        fd, temp_name = tempfile.mkstemp(prefix="wzc-legacy-", dir=self.settings.upload_dir)
        temp = Path(temp_name)
        try:
            with os.fdopen(fd, "wb") as out, part.open("rb") as handle:
                for chunk in SegmentReader(handle, self.store.keyring).iter_all():
                    out.write(chunk)
            return self.legacy.store(temp, principal.telegram_user_id, row["filename"], row["mime_type"])
        finally:
            temp.unlink(missing_ok=True)

    def _fail(self, upload_id: str) -> None:
        with self.db.tx() as conn:
            conn.execute(
                "UPDATE mobile_uploads SET status = 'failed', updated_at = ? WHERE id = ?", (self._now(), upload_id)
            )
        self.store.part_path(upload_id).unlink(missing_ok=True)

    def cancel(self, principal: Principal, upload_id: str) -> None:
        lock = self._lock(upload_id)
        with lock:
            with self.db.tx() as conn:
                cursor = conn.execute(
                    "UPDATE mobile_uploads SET status = 'cancelled', updated_at = ? WHERE id = ? AND user_id = ? AND status = 'active'",
                    (self._now(), upload_id, principal.user_id),
                )
            if cursor.rowcount == 0:
                raise not_found("upload_not_found", "Upload not found")
            self.store.part_path(upload_id).unlink(missing_ok=True)
        self._release_lock_entry(upload_id)

    def purge(self) -> int:
        now = self._now()
        removed = 0
        with self.db.tx() as conn:
            rows = conn.execute(
                "SELECT id FROM mobile_uploads WHERE (status = 'active' AND expires_at <= ?) OR status IN ('cancelled','failed')",
                (now,),
            ).fetchall()
            conn.execute(
                "UPDATE mobile_uploads SET status = 'cancelled', updated_at = ? WHERE status = 'active' AND expires_at <= ?",
                (now, now),
            )
            conn.execute(
                "DELETE FROM mobile_uploads WHERE status IN ('cancelled','failed','completed') AND updated_at < ?",
                (now - 30 * 86400,),
            )
        for row in rows:
            path = self.store.part_path(row["id"])
            if path.exists():
                path.unlink()
                removed += 1
        return removed
