"""Library, albums, thumbnails and range-capable content access."""

from __future__ import annotations

import base64
import binascii
import calendar
import json
import sqlite3
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .auth_service import Principal
from .config import MobileSettings
from .db import Database
from .errors import APIError, bad_request, not_found
from .legacy import LegacyBridge
from .security import new_id
from .storage import ObjectStore

MEDIA_COLUMNS = (
    "m.id, m.filename, m.mime_type, m.media_type, m.size_bytes, m.sha256, m.width, m.height, m.duration_ms, "
    "m.taken_at, m.added_at, m.is_favorite, m.is_screenshot, m.storage_kind, m.storage_ref, m.thumb_ref"
)

GRANULARITY_FORMATS = {"day": "%Y-%m-%d", "month": "%Y-%m", "year": "%Y"}


def media_dict(row: sqlite3.Row, has_preview_hook: bool = False) -> dict:
    return {
        "id": row["id"],
        "filename": row["filename"],
        "mime_type": row["mime_type"],
        "media_type": row["media_type"],
        "size_bytes": row["size_bytes"],
        "sha256": row["sha256"],
        "width": row["width"],
        "height": row["height"],
        "duration_ms": row["duration_ms"],
        "taken_at": row["taken_at"],
        "added_at": row["added_at"],
        "is_favorite": bool(row["is_favorite"]),
        "is_screenshot": bool(row["is_screenshot"]),
        "has_thumbnail": row["thumb_ref"] is not None or (row["storage_kind"] == "legacy" and has_preview_hook),
        "storage_kind": row["storage_kind"],
    }


def _encode_cursor(value: int, media_id: str) -> str:
    return base64.urlsafe_b64encode(json.dumps([value, media_id]).encode()).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[int, str]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        value, media_id = json.loads(raw)
        if not isinstance(value, int) or not isinstance(media_id, str) or len(media_id) > 64:
            raise ValueError
        return value, media_id
    except (binascii.Error, ValueError, TypeError) as exc:
        raise bad_request("invalid_cursor", "cursor is invalid") from exc


def _escape_like(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def bucket_bounds(key: str, granularity: str, tz_offset_minutes: int) -> tuple[int, int]:
    tz = timezone(timedelta(minutes=tz_offset_minutes))
    if granularity == "day":
        start = datetime.strptime(key, "%Y-%m-%d").replace(tzinfo=tz)
        end = start + timedelta(days=1)
    elif granularity == "month":
        start = datetime.strptime(key, "%Y-%m").replace(tzinfo=tz)
        days = calendar.monthrange(start.year, start.month)[1]
        end = start + timedelta(days=days)
    else:
        start = datetime.strptime(key, "%Y").replace(tzinfo=tz)
        end = start.replace(year=start.year + 1)
    return int(start.timestamp()), int(end.timestamp()) - 1


@dataclass(frozen=True)
class ContentSource:
    size: int
    mime_type: str
    filename: str
    opener: Callable[[int, int], Iterator[bytes]]


@dataclass(frozen=True)
class LibraryQuery:
    cursor: str | None = None
    limit: int = 200
    media_type: str | None = None
    favorite: bool | None = None
    screenshot: bool | None = None
    q: str | None = None
    date_from: int | None = None
    date_to: int | None = None
    album_id: str | None = None
    added_since: int | None = None
    sort: str = "taken"


class MediaService:
    def __init__(self, db: Database, settings: MobileSettings, store: ObjectStore, legacy: LegacyBridge, clock: Callable[[], float] = time.time) -> None:
        self.db = db
        self.settings = settings
        self.store = store
        self.legacy = legacy
        self.clock = clock

    def _now(self) -> int:
        return int(self.clock())

    def _dict(self, row: sqlite3.Row) -> dict:
        return media_dict(row, self.legacy._preview is not None)

    # ------------------------------------------------------------------ media

    def find_by_sha(self, user_id: int, sha256: str) -> dict | None:
        with self.db.read() as conn:
            row = conn.execute(f"SELECT {MEDIA_COLUMNS} FROM mobile_media m WHERE m.user_id = ? AND m.sha256 = ?", (user_id, sha256)).fetchone()
        return self._dict(row) if row else None

    def check_hashes(self, principal: Principal, hashes: list[str]) -> dict[str, str]:
        if not hashes:
            return {}
        found: dict[str, str] = {}
        with self.db.read() as conn:
            for start in range(0, len(hashes), 400):
                batch = hashes[start : start + 400]
                placeholders = ",".join("?" for _ in batch)
                for row in conn.execute(
                    f"SELECT sha256, id FROM mobile_media WHERE user_id = ? AND sha256 IN ({placeholders})",
                    (principal.user_id, *batch),
                ):
                    found[row["sha256"]] = row["id"]
        return found

    def insert(self, *, media_id: str, user_id: int, device_id: str | None, filename: str, mime_type: str, media_type: str,
               size_bytes: int, sha256: str, metadata: dict, storage_kind: str, storage_ref: str) -> dict:
        now = self._now()
        taken_at = metadata.get("taken_at")
        if not isinstance(taken_at, int) or taken_at <= 0 or taken_at > now + 86400:
            taken_at = now
        with self.db.tx() as conn:
            try:
                conn.execute(
                    """INSERT INTO mobile_media(id, user_id, filename, mime_type, media_type, size_bytes, sha256, width, height,
                           duration_ms, taken_at, added_at, is_favorite, is_screenshot, storage_kind, storage_ref, thumb_ref,
                           local_identifier, source_device_id)
                       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,?,?)""",
                    (media_id, user_id, filename, mime_type, media_type, size_bytes, sha256, metadata.get("width"),
                     metadata.get("height"), metadata.get("duration_ms"), taken_at, now, int(bool(metadata.get("is_favorite"))),
                     int(bool(metadata.get("is_screenshot"))), storage_kind, storage_ref, metadata.get("local_identifier"), device_id),
                )
            except sqlite3.IntegrityError as exc:
                raise APIError(409, "duplicate", "This content already exists in the library") from exc
            row = conn.execute(f"SELECT {MEDIA_COLUMNS} FROM mobile_media m WHERE m.id = ?", (media_id,)).fetchone()
        return self._dict(row)

    def _row(self, conn: sqlite3.Connection, principal: Principal, media_id: str) -> sqlite3.Row:
        row = conn.execute(
            f"SELECT {MEDIA_COLUMNS} FROM mobile_media m WHERE m.id = ? AND m.user_id = ?", (media_id, principal.user_id)
        ).fetchone()
        if row is None:
            raise not_found("media_not_found", "Media not found")
        return row

    def get(self, principal: Principal, media_id: str) -> dict:
        with self.db.read() as conn:
            row = self._row(conn, principal, media_id)
            album_ids = [r["album_id"] for r in conn.execute("SELECT album_id FROM mobile_album_items WHERE media_id = ?", (media_id,))]
        result = self._dict(row)
        result["album_ids"] = album_ids
        return result

    def update(self, principal: Principal, media_id: str, *, filename: str | None, is_favorite: bool | None) -> dict:
        from .uploads import sanitize_filename

        with self.db.tx() as conn:
            self._row(conn, principal, media_id)
            if filename is not None:
                conn.execute("UPDATE mobile_media SET filename = ? WHERE id = ?", (sanitize_filename(filename), media_id))
            if is_favorite is not None:
                conn.execute("UPDATE mobile_media SET is_favorite = ? WHERE id = ?", (int(is_favorite), media_id))
        return self.get(principal, media_id)

    def set_favorite_bulk(self, principal: Principal, media_ids: list[str], favorite: bool) -> int:
        with self.db.tx() as conn:
            total = 0
            for media_id in media_ids:
                total += conn.execute(
                    "UPDATE mobile_media SET is_favorite = ? WHERE id = ? AND user_id = ?", (int(favorite), media_id, principal.user_id)
                ).rowcount
        return total

    def delete(self, principal: Principal, media_ids: list[str]) -> int:
        refs: list[tuple[str, str | None, str]] = []
        with self.db.tx() as conn:
            for media_id in media_ids:
                row = conn.execute(
                    "SELECT storage_kind, storage_ref, thumb_ref FROM mobile_media WHERE id = ? AND user_id = ?",
                    (media_id, principal.user_id),
                ).fetchone()
                if row is None:
                    continue
                conn.execute("DELETE FROM mobile_media WHERE id = ?", (media_id,))
                refs.append((row["storage_kind"], row["thumb_ref"], row["storage_ref"]))
            conn.execute(
                "INSERT INTO mobile_audit(user_id, device_id, event, detail, created_at) VALUES (?,?,?,?,?)",
                (principal.user_id, principal.device_id, "media.deleted", str(len(refs)), self._now()),
            )
        for kind, thumb_ref, storage_ref in refs:
            self.store.delete(thumb_ref)
            if kind == "wzc2":
                self.store.delete(storage_ref)
            # Legacy (WZC1) objects are owned by the existing studio and are never deleted from here.
        return len(refs)

    # ---------------------------------------------------------------- listing

    def list(self, principal: Principal, query: LibraryQuery) -> dict:
        limit = max(1, min(query.limit, self.settings.library_page_max))
        column = "added_at" if query.sort == "added" else "taken_at"
        joins = ""
        where = ["m.user_id = ?"]
        params: list = [principal.user_id]
        if query.album_id:
            self._album_row(principal, query.album_id)
            joins = "JOIN mobile_album_items ai ON ai.media_id = m.id AND ai.album_id = ?"
            params.insert(0, query.album_id)
        if query.media_type in {"photo", "video"}:
            where.append("m.media_type = ?")
            params.append(query.media_type)
        if query.favorite is not None:
            where.append("m.is_favorite = ?")
            params.append(int(query.favorite))
        if query.screenshot is not None:
            where.append("m.is_screenshot = ?")
            params.append(int(query.screenshot))
        if query.q:
            where.append("m.filename LIKE ? ESCAPE '\\'")
            params.append(f"%{_escape_like(query.q.strip()[:200])}%")
        if query.date_from is not None:
            where.append("m.taken_at >= ?")
            params.append(query.date_from)
        if query.date_to is not None:
            where.append("m.taken_at <= ?")
            params.append(query.date_to)
        if query.added_since is not None:
            where.append("m.added_at >= ?")
            params.append(query.added_since)
        if query.cursor:
            value, media_id = _decode_cursor(query.cursor)
            where.append(f"(m.{column} < ? OR (m.{column} = ? AND m.id < ?))")
            params.extend([value, value, media_id])
        sql = (
            f"SELECT {MEDIA_COLUMNS} FROM mobile_media m {joins} WHERE {' AND '.join(where)} "
            f"ORDER BY m.{column} DESC, m.id DESC LIMIT ?"
        )
        params.append(limit + 1)
        with self.db.read() as conn:
            rows = conn.execute(sql, params).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]
        next_cursor = _encode_cursor(rows[-1][column], rows[-1]["id"]) if has_more and rows else None
        return {"items": [self._dict(row) for row in rows], "next_cursor": next_cursor}

    def summary(self, principal: Principal, granularity: str, tz_offset_minutes: int, before: str | None, limit: int, media_type: str | None) -> dict:
        if granularity not in GRANULARITY_FORMATS:
            raise bad_request("invalid_granularity", "granularity must be day, month or year")
        if not -14 * 60 <= tz_offset_minutes <= 14 * 60:
            raise bad_request("invalid_tz", "tz_offset_minutes out of range")
        limit = max(1, min(limit, 1000))
        fmt = GRANULARITY_FORMATS[granularity]
        where = "m.user_id = ?"
        params: list = [fmt, tz_offset_minutes * 60, principal.user_id]
        if media_type in {"photo", "video"}:
            where += " AND m.media_type = ?"
            params.append(media_type)
        having = ""
        if before:
            having = "HAVING bucket < ?"
            params.append(before)
        params.append(limit + 1)
        sql = (
            "SELECT strftime(?, m.taken_at + ?, 'unixepoch') AS bucket, COUNT(*) AS item_count, "
            "COALESCE(SUM(m.size_bytes), 0) AS total_bytes, MAX(m.taken_at) AS latest, m.id AS cover_media_id "
            f"FROM mobile_media m WHERE {where} GROUP BY bucket {having} ORDER BY bucket DESC LIMIT ?"
        )
        with self.db.read() as conn:
            rows = conn.execute(sql, params).fetchall()
        has_more = len(rows) > limit
        rows = rows[:limit]
        buckets = []
        for row in rows:
            start, end = bucket_bounds(row["bucket"], granularity, tz_offset_minutes)
            buckets.append({
                "key": row["bucket"],
                "count": row["item_count"],
                "total_bytes": row["total_bytes"],
                "cover_media_id": row["cover_media_id"],
                "start": start,
                "end": end,
            })
        return {"buckets": buckets, "next_before": rows[-1]["bucket"] if has_more and rows else None}

    def account(self, principal: Principal) -> dict:
        with self.db.read() as conn:
            row = conn.execute(
                """SELECT COUNT(*) AS total, COALESCE(SUM(size_bytes),0) AS bytes,
                          SUM(CASE WHEN media_type='photo' THEN 1 ELSE 0 END) AS photos,
                          SUM(CASE WHEN media_type='video' THEN 1 ELSE 0 END) AS videos,
                          SUM(CASE WHEN is_favorite=1 THEN 1 ELSE 0 END) AS favorites
                   FROM mobile_media WHERE user_id = ?""",
                (principal.user_id,),
            ).fetchone()
            albums = conn.execute("SELECT COUNT(*) FROM mobile_albums WHERE user_id = ?", (principal.user_id,)).fetchone()[0]
        return {
            "telegram_user_id": principal.telegram_user_id,
            "device_id": principal.device_id,
            "media_count": row["total"],
            "photo_count": row["photos"] or 0,
            "video_count": row["videos"] or 0,
            "favorite_count": row["favorites"] or 0,
            "album_count": albums,
            "total_bytes": row["bytes"],
            "storage_format": self.settings.storage_format,
            "encryption": {
                "algorithm": "AES-256-GCM",
                "container": "WZC2" if self.settings.storage_format == "wzc2" else "WZC1 (existing studio)",
                "key_management": "server-held master key, per-file random data key",
                "end_to_end": False,
            },
            "limits": {
                "max_file_size": self.settings.max_file_size,
                "chunk_size": self.settings.chunk_size,
                "segment_size": self.settings.segment_size,
            },
        }

    # ------------------------------------------------------------- thumbnails

    def put_thumbnail(self, principal: Principal, media_id: str, data: bytes) -> None:
        if not data:
            raise bad_request("empty_thumbnail", "Thumbnail is empty")
        if len(data) > self.settings.thumbnail_max_bytes:
            raise APIError(413, "payload_too_large", "Thumbnail too large")
        if not (data[:3] == b"\xff\xd8\xff" or data[:8] == b"\x89PNG\r\n\x1a\n"):
            raise bad_request("invalid_thumbnail", "Thumbnail must be JPEG or PNG")
        with self.db.read() as conn:
            row = self._row(conn, principal, media_id)
        ref = row["thumb_ref"] or ObjectStore.new_ref(media_id, "thumbs")
        self.store.write_small(ref, data)
        with self.db.tx() as conn:
            conn.execute("UPDATE mobile_media SET thumb_ref = ? WHERE id = ?", (ref, media_id))

    def thumbnail(self, principal: Principal, media_id: str) -> tuple[bytes, str]:
        with self.db.read() as conn:
            row = self._row(conn, principal, media_id)
        if row["thumb_ref"]:
            data = self.store.read_small(row["thumb_ref"])
        elif row["storage_kind"] == "legacy":
            preview = self.legacy.preview(row["storage_ref"], principal.telegram_user_id)
            if preview is None:
                raise not_found("thumbnail_not_found", "No thumbnail available")
            data = bytes(preview)
            ref = ObjectStore.new_ref(media_id, "thumbs")
            self.store.write_small(ref, data)
            with self.db.tx() as conn:
                conn.execute("UPDATE mobile_media SET thumb_ref = ? WHERE id = ?", (ref, media_id))
        else:
            raise not_found("thumbnail_not_found", "No thumbnail available")
        mime = "image/png" if data[:8] == b"\x89PNG\r\n\x1a\n" else "image/jpeg"
        return data, mime

    # ---------------------------------------------------------------- content

    def content_source(self, principal: Principal, media_id: str) -> ContentSource:
        with self.db.read() as conn:
            row = self._row(conn, principal, media_id)
        if row["storage_kind"] == "wzc2":
            ref = row["storage_ref"]
            size = row["size_bytes"]

            def open_wzc2(start: int, end: int) -> Iterator[bytes]:
                return self.store.iter_range(ref, start, end)

            return ContentSource(size=size, mime_type=row["mime_type"], filename=row["filename"], opener=open_wzc2)

        path: Path = self.legacy.plaintext_path(row["storage_ref"], principal.telegram_user_id)
        size = path.stat().st_size

        def open_plain(start: int, end: int) -> Iterator[bytes]:
            with path.open("rb") as handle:
                handle.seek(start)
                remaining = end - start + 1
                while remaining > 0:
                    chunk = handle.read(min(1024 * 1024, remaining))
                    if not chunk:
                        break
                    remaining -= len(chunk)
                    yield chunk

        return ContentSource(size=size, mime_type=row["mime_type"], filename=row["filename"], opener=open_plain)

    # ----------------------------------------------------------------- albums

    def _album_row(self, principal: Principal, album_id: str, conn: sqlite3.Connection | None = None) -> sqlite3.Row:
        def fetch(c: sqlite3.Connection):
            return c.execute("SELECT * FROM mobile_albums WHERE id = ? AND user_id = ?", (album_id, principal.user_id)).fetchone()

        if conn is not None:
            row = fetch(conn)
        else:
            with self.db.read() as c:
                row = fetch(c)
        if row is None:
            raise not_found("album_not_found", "Album not found")
        return row

    def _album_dict(self, row: sqlite3.Row) -> dict:
        return {
            "id": row["id"],
            "name": row["name"],
            "item_count": row["item_count"],
            "total_bytes": row["total_bytes"],
            "cover_media_id": row["cover_media_id"],
            "created_at": row["created_at"],
            "updated_at": row["updated_at"],
        }

    def _smart(self, conn: sqlite3.Connection, user_id: int, condition: str, params: tuple = ()) -> dict:
        row = conn.execute(
            f"""SELECT COUNT(m.id) AS item_count, COALESCE(SUM(m.size_bytes),0) AS total_bytes,
                       m.id AS cover_media_id, MAX(m.taken_at) AS latest
                FROM mobile_media m WHERE m.user_id = ? AND {condition}""",
            (user_id, *params),
        ).fetchone()
        return {"item_count": row["item_count"], "total_bytes": row["total_bytes"], "cover_media_id": row["cover_media_id"]}

    def list_albums(self, principal: Principal) -> dict:
        with self.db.read() as conn:
            rows = conn.execute(
                """SELECT a.id, a.name, a.created_at, a.updated_at, COUNT(m.id) AS item_count,
                          COALESCE(SUM(m.size_bytes), 0) AS total_bytes, m.id AS cover_media_id, MAX(m.taken_at) AS latest
                   FROM mobile_albums a
                   LEFT JOIN mobile_album_items ai ON ai.album_id = a.id
                   LEFT JOIN mobile_media m ON m.id = ai.media_id
                   WHERE a.user_id = ? GROUP BY a.id ORDER BY a.updated_at DESC""",
                (principal.user_id,),
            ).fetchall()
            recent_since = self._now() - 30 * 86400
            smart = {
                "favorites": self._smart(conn, principal.user_id, "m.is_favorite = 1"),
                "videos": self._smart(conn, principal.user_id, "m.media_type = 'video'"),
                "screenshots": self._smart(conn, principal.user_id, "m.is_screenshot = 1"),
                "recently_added": self._smart(conn, principal.user_id, "m.added_at >= ?", (recent_since,)),
            }
        return {"albums": [self._album_dict(row) for row in rows], "smart": smart, "recently_added_since": recent_since}

    def _album_with_stats(self, conn: sqlite3.Connection, album_id: str) -> dict:
        row = conn.execute(
            """SELECT a.id, a.name, a.created_at, a.updated_at, COUNT(m.id) AS item_count,
                      COALESCE(SUM(m.size_bytes), 0) AS total_bytes, m.id AS cover_media_id, MAX(m.taken_at) AS latest
               FROM mobile_albums a
               LEFT JOIN mobile_album_items ai ON ai.album_id = a.id
               LEFT JOIN mobile_media m ON m.id = ai.media_id
               WHERE a.id = ? GROUP BY a.id""",
            (album_id,),
        ).fetchone()
        return self._album_dict(row)

    @staticmethod
    def _clean_album_name(name: str) -> str:
        cleaned = " ".join(name.split())
        if not cleaned:
            raise bad_request("invalid_name", "Album name cannot be empty")
        if len(cleaned) > 120:
            raise bad_request("invalid_name", "Album name is too long")
        return cleaned

    def create_album(self, principal: Principal, name: str, media_ids: list[str]) -> dict:
        now = self._now()
        album_id = new_id()
        with self.db.tx() as conn:
            count = conn.execute("SELECT COUNT(*) FROM mobile_albums WHERE user_id = ?", (principal.user_id,)).fetchone()[0]
            if count >= 5000:
                raise APIError(429, "too_many_albums", "Album limit reached")
            conn.execute(
                "INSERT INTO mobile_albums(id, user_id, name, created_at, updated_at) VALUES (?,?,?,?,?)",
                (album_id, principal.user_id, self._clean_album_name(name), now, now),
            )
            self._add_items(conn, principal, album_id, media_ids, now)
            return self._album_with_stats(conn, album_id)

    def rename_album(self, principal: Principal, album_id: str, name: str) -> dict:
        with self.db.tx() as conn:
            self._album_row(principal, album_id, conn)
            conn.execute(
                "UPDATE mobile_albums SET name = ?, updated_at = ? WHERE id = ?",
                (self._clean_album_name(name), self._now(), album_id),
            )
            return self._album_with_stats(conn, album_id)

    def delete_album(self, principal: Principal, album_id: str) -> None:
        with self.db.tx() as conn:
            self._album_row(principal, album_id, conn)
            conn.execute("DELETE FROM mobile_albums WHERE id = ?", (album_id,))

    def _add_items(self, conn: sqlite3.Connection, principal: Principal, album_id: str, media_ids: list[str], now: int) -> int:
        added = 0
        for media_id in media_ids:
            owned = conn.execute("SELECT 1 FROM mobile_media WHERE id = ? AND user_id = ?", (media_id, principal.user_id)).fetchone()
            if owned is None:
                continue
            added += conn.execute(
                "INSERT OR IGNORE INTO mobile_album_items(album_id, media_id, added_at) VALUES (?,?,?)", (album_id, media_id, now)
            ).rowcount
        return added

    def add_to_album(self, principal: Principal, album_id: str, media_ids: list[str]) -> dict:
        now = self._now()
        with self.db.tx() as conn:
            self._album_row(principal, album_id, conn)
            self._add_items(conn, principal, album_id, media_ids, now)
            conn.execute("UPDATE mobile_albums SET updated_at = ? WHERE id = ?", (now, album_id))
            return self._album_with_stats(conn, album_id)

    def remove_from_album(self, principal: Principal, album_id: str, media_ids: list[str]) -> dict:
        now = self._now()
        with self.db.tx() as conn:
            self._album_row(principal, album_id, conn)
            for media_id in media_ids:
                conn.execute("DELETE FROM mobile_album_items WHERE album_id = ? AND media_id = ?", (album_id, media_id))
            conn.execute("UPDATE mobile_albums SET updated_at = ? WHERE id = ?", (now, album_id))
            return self._album_with_stats(conn, album_id)

    # ---------------------------------------------------------- legacy import

    def import_legacy(self, telegram_user_id: int, entries) -> tuple[int, int]:
        imported = skipped = 0
        now = self._now()
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM mobile_users WHERE telegram_user_id = ?", (telegram_user_id,)).fetchone()
            if row is None:
                user_id = conn.execute(
                    "INSERT INTO mobile_users(telegram_user_id, created_at) VALUES (?, ?)", (telegram_user_id, now)
                ).lastrowid
            else:
                user_id = row["id"]
            for entry in entries:
                file_ref = str(entry["file_ref"])
                mime = str(entry.get("mime_type") or "application/octet-stream").lower()
                media_type = "video" if mime.startswith("video/") else "photo"
                sha = entry.get("sha256") or f"legacy:{file_ref}"
                exists = conn.execute(
                    "SELECT 1 FROM mobile_media WHERE user_id = ? AND (sha256 = ? OR (storage_kind='legacy' AND storage_ref = ?))",
                    (user_id, sha, file_ref),
                ).fetchone()
                if exists:
                    skipped += 1
                    continue
                taken = entry.get("taken_at")
                conn.execute(
                    """INSERT INTO mobile_media(id, user_id, filename, mime_type, media_type, size_bytes, sha256, taken_at, added_at,
                           storage_kind, storage_ref) VALUES (?,?,?,?,?,?,?,?,?, 'legacy', ?)""",
                    (new_id(), user_id, str(entry.get("filename") or file_ref)[:255], mime, media_type,
                     int(entry.get("size_bytes") or 0), sha, int(taken) if taken else now, now, file_ref),
                )
                imported += 1
        return imported, skipped
