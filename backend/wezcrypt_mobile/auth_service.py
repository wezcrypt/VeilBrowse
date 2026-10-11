"""Device pairing, token issuance, refresh rotation and device revocation.

Pairing flow (no Telegram initData is ever used by the native app):

1. The app generates a P-256 key in the Secure Enclave and calls
   ``POST /api/mobile/pair/start`` with its public key. The server returns a
   short-lived human code (e.g. ``K7Q2-9XMD``), a pairing id and a poll secret.
2. The owner sends ``/pair K7Q2-9XMD`` (or opens the ``t.me`` deep link) to the
   existing Telegram bot. The bot runs on the server and calls
   :meth:`AuthService.approve_pairing` with the Telegram user id that Telegram
   itself delivered with the message.
3. The app polls ``POST /api/mobile/pair/poll`` and receives its first token
   pair exactly once.

Refreshing requires a signature from the device key, so a leaked refresh token
alone cannot mint new sessions.
"""

from __future__ import annotations

import base64
import binascii
import logging
import sqlite3
import time
from collections.abc import Callable
from dataclasses import dataclass

from .config import MobileSettings
from .db import Database
from .errors import APIError, bad_request, forbidden, not_found, unauthorized
from .security import (
    constant_time_equals,
    hash_token,
    new_id,
    new_pairing_code,
    new_token,
    normalize_pairing_code,
    normalize_public_key,
    refresh_message,
    verify_device_signature,
)

logger = logging.getLogger("wezcrypt_mobile.auth")

ACCESS_PREFIX = "wza_"
REFRESH_PREFIX = "wzr_"
POLL_PREFIX = "wzp_"


@dataclass(frozen=True)
class Principal:
    user_id: int
    telegram_user_id: int
    device_id: str


class AuthService:
    def __init__(self, db: Database, settings: MobileSettings, clock: Callable[[], float] = time.time) -> None:
        self.db = db
        self.settings = settings
        self.clock = clock

    def _now(self) -> int:
        return int(self.clock())

    def _hash(self, token: str) -> str:
        return hash_token(self.settings.token_pepper, token)

    def audit(self, conn: sqlite3.Connection, event: str, *, user_id: int | None = None, device_id: str | None = None, detail: str | None = None, client_ip: str | None = None) -> None:
        conn.execute(
            "INSERT INTO mobile_audit(user_id, device_id, event, detail, client_ip, created_at) VALUES (?,?,?,?,?,?)",
            (user_id, device_id, event, detail, client_ip, self._now()),
        )

    # ------------------------------------------------------------------ pairing

    def start_pairing(self, *, device_name: str, device_model: str, system_version: str, public_key_b64: str, client_ip: str | None) -> dict:
        try:
            raw_key = base64.b64decode(public_key_b64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise bad_request("invalid_public_key", "public_key must be base64") from exc
        try:
            public_key = normalize_public_key(raw_key)
        except ValueError as exc:
            raise bad_request("invalid_public_key", str(exc)) from exc

        now = self._now()
        pairing_id = new_id()
        poll_secret = new_token(POLL_PREFIX)
        expires_at = now + self.settings.pairing_ttl
        with self.db.tx() as conn:
            conn.execute("DELETE FROM mobile_pairings WHERE expires_at < ? AND status != 'approved'", (now - 3600,))
            for _ in range(5):
                code = new_pairing_code()
                normalized = normalize_pairing_code(code)
                assert normalized is not None
                try:
                    conn.execute(
                        """INSERT INTO mobile_pairings(id, code_hash, poll_secret_hash, device_name, device_model,
                               system_version, public_key, status, client_ip, created_at, expires_at)
                           VALUES (?,?,?,?,?,?,?, 'pending', ?, ?, ?)""",
                        (pairing_id, self._hash("pair:" + normalized), self._hash(poll_secret), device_name, device_model,
                         system_version, public_key, client_ip, now, expires_at),
                    )
                    break
                except sqlite3.IntegrityError:
                    continue
            else:
                raise APIError(503, "pairing_unavailable", "Could not allocate a pairing code, try again")
            self.audit(conn, "pair.start", detail=device_model, client_ip=client_ip)

        bot = self.settings.bot_username
        compact = code.replace("-", "")
        return {
            "pairing_id": pairing_id,
            "code": code,
            "poll_secret": poll_secret,
            "expires_at": expires_at,
            "poll_interval": 3,
            "bot_username": bot,
            "telegram_link": f"https://t.me/{bot}?start=pair_{compact}" if bot else None,
        }

    def approve_pairing(self, code: str, telegram_user_id: int) -> dict:
        allowed = self.settings.allowed_telegram_ids
        if allowed and telegram_user_id not in allowed:
            raise forbidden("not_allowed", "This Telegram account is not allowed to pair devices")
        normalized = normalize_pairing_code(code)
        if normalized is None:
            raise not_found("pairing_not_found", "Unknown or expired pairing code")
        now = self._now()
        with self.db.tx() as conn:
            row = conn.execute(
                "SELECT id, device_name, device_model, status, expires_at FROM mobile_pairings WHERE code_hash = ?",
                (self._hash("pair:" + normalized),),
            ).fetchone()
            if row is None or row["status"] != "pending" or row["expires_at"] < now:
                raise not_found("pairing_not_found", "Unknown or expired pairing code")
            user_id = self._ensure_user(conn, telegram_user_id)
            conn.execute("UPDATE mobile_pairings SET status = 'approved', user_id = ? WHERE id = ?", (user_id, row["id"]))
            self.audit(conn, "pair.approve", user_id=user_id, detail=row["device_model"])
        return {"device_name": row["device_name"], "device_model": row["device_model"]}

    def poll_pairing(self, pairing_id: str, poll_secret: str) -> dict:
        now = self._now()
        with self.db.tx() as conn:
            row = conn.execute("SELECT * FROM mobile_pairings WHERE id = ?", (pairing_id,)).fetchone()
            if row is None or not constant_time_equals(row["poll_secret_hash"], self._hash(poll_secret)):
                raise not_found("pairing_not_found", "Unknown pairing")
            status = row["status"]
            if status == "pending":
                if row["expires_at"] < now:
                    return {"status": "expired"}
                return {"status": "pending"}
            if status == "consumed":
                return {"status": "consumed"}
            if row["expires_at"] + 600 < now:
                return {"status": "expired"}
            device_id = new_id()
            conn.execute(
                """INSERT INTO mobile_devices(id, user_id, name, model, system_version, public_key, created_at, last_seen_at)
                   VALUES (?,?,?,?,?,?,?,?)""",
                (device_id, row["user_id"], row["device_name"], row["device_model"], row["system_version"], row["public_key"], now, now),
            )
            conn.execute("UPDATE mobile_pairings SET status = 'consumed', device_id = ? WHERE id = ?", (device_id, pairing_id))
            session = self._issue_tokens(conn, device_id, parent_hash=None)
            self.audit(conn, "device.created", user_id=row["user_id"], device_id=device_id, detail=row["device_model"])
        return {"status": "approved", "session": session}

    def _ensure_user(self, conn: sqlite3.Connection, telegram_user_id: int) -> int:
        row = conn.execute("SELECT id FROM mobile_users WHERE telegram_user_id = ?", (telegram_user_id,)).fetchone()
        if row:
            return int(row["id"])
        cursor = conn.execute(
            "INSERT INTO mobile_users(telegram_user_id, created_at) VALUES (?, ?)", (telegram_user_id, self._now())
        )
        return int(cursor.lastrowid)

    # ------------------------------------------------------------------- tokens

    def _issue_tokens(self, conn: sqlite3.Connection, device_id: str, parent_hash: str | None) -> dict:
        now = self._now()
        access = new_token(ACCESS_PREFIX)
        refresh = new_token(REFRESH_PREFIX)
        access_exp = now + self.settings.access_ttl
        refresh_exp = now + self.settings.refresh_ttl
        conn.execute(
            "INSERT INTO mobile_tokens(token_hash, device_id, kind, parent_hash, created_at, expires_at) VALUES (?,?,?,?,?,?)",
            (self._hash(access), device_id, "access", parent_hash, now, access_exp),
        )
        conn.execute(
            "INSERT INTO mobile_tokens(token_hash, device_id, kind, parent_hash, created_at, expires_at) VALUES (?,?,?,?,?,?)",
            (self._hash(refresh), device_id, "refresh", parent_hash, now, refresh_exp),
        )
        return {
            "device_id": device_id,
            "access_token": access,
            "access_expires_at": access_exp,
            "refresh_token": refresh,
            "refresh_expires_at": refresh_exp,
        }

    def authenticate(self, access_token: str) -> Principal:
        if not access_token.startswith(ACCESS_PREFIX) or len(access_token) > 128:
            raise unauthorized("invalid_token", "Invalid access token")
        now = self._now()
        with self.db.read() as conn:
            row = conn.execute(
                """SELECT t.device_id, t.expires_at, t.revoked_at, d.revoked_at AS device_revoked, d.user_id,
                          d.last_seen_at, u.telegram_user_id
                   FROM mobile_tokens t
                   JOIN mobile_devices d ON d.id = t.device_id
                   JOIN mobile_users u ON u.id = d.user_id
                   WHERE t.token_hash = ? AND t.kind = 'access'""",
                (self._hash(access_token),),
            ).fetchone()
        if row is None or row["revoked_at"] is not None or row["device_revoked"] is not None:
            raise unauthorized("invalid_token", "Invalid access token")
        if row["expires_at"] <= now:
            raise unauthorized("token_expired", "Access token expired")
        if now - row["last_seen_at"] > 300:
            with self.db.tx() as conn:
                conn.execute("UPDATE mobile_devices SET last_seen_at = ? WHERE id = ?", (now, row["device_id"]))
        return Principal(user_id=int(row["user_id"]), telegram_user_id=int(row["telegram_user_id"]), device_id=row["device_id"])

    def refresh(self, *, device_id: str, refresh_token: str, timestamp: int, signature_b64: str, client_ip: str | None) -> dict:
        now = self._now()
        if abs(now - timestamp) > self.settings.signature_skew:
            raise unauthorized("clock_skew", "Request timestamp outside the allowed window")
        try:
            signature = base64.b64decode(signature_b64, validate=True)
        except (binascii.Error, ValueError) as exc:
            raise unauthorized("invalid_signature", "Invalid signature") from exc
        token_hash = self._hash(refresh_token)
        error: APIError | None = None
        result: dict | None = None
        # Security events (bad signature, reuse) must be committed before the
        # error is raised, so the transaction body records an error instead.
        with self.db.tx() as conn:
            row = conn.execute(
                """SELECT t.*, d.public_key, d.revoked_at AS device_revoked, d.user_id
                   FROM mobile_tokens t JOIN mobile_devices d ON d.id = t.device_id
                   WHERE t.token_hash = ? AND t.kind = 'refresh'""",
                (token_hash,),
            ).fetchone()
            if row is None or row["device_id"] != device_id or row["device_revoked"] is not None:
                error = unauthorized("invalid_token", "Invalid refresh token")
            elif not verify_device_signature(row["public_key"], refresh_message(device_id, timestamp, refresh_token), signature):
                self.audit(conn, "refresh.bad_signature", user_id=row["user_id"], device_id=device_id, client_ip=client_ip)
                error = unauthorized("invalid_signature", "Invalid signature")
            elif row["revoked_at"] is not None or row["expires_at"] <= now:
                error = unauthorized("invalid_token", "Refresh token expired or revoked")
            elif row["used_at"] is not None:
                if now - row["used_at"] <= self.settings.refresh_grace:
                    # The client lost the previous response; replace that rotation.
                    conn.execute(
                        "UPDATE mobile_tokens SET revoked_at = ? WHERE parent_hash = ? AND revoked_at IS NULL",
                        (now, token_hash),
                    )
                    self.audit(conn, "refresh.retry", user_id=row["user_id"], device_id=device_id, client_ip=client_ip)
                    result = self._issue_tokens(conn, device_id, parent_hash=token_hash)
                else:
                    self._revoke_device_tokens(conn, device_id, now)
                    conn.execute("UPDATE mobile_devices SET revoked_at = ? WHERE id = ?", (now, device_id))
                    self.audit(conn, "refresh.reuse_detected", user_id=row["user_id"], device_id=device_id, client_ip=client_ip)
                    error = unauthorized("refresh_reuse", "Refresh token reuse detected; device signed out")
            else:
                conn.execute("UPDATE mobile_tokens SET used_at = ? WHERE token_hash = ?", (now, token_hash))
                conn.execute("UPDATE mobile_devices SET last_seen_at = ? WHERE id = ?", (now, device_id))
                conn.execute("DELETE FROM mobile_tokens WHERE expires_at < ?", (now - 86400,))
                result = self._issue_tokens(conn, device_id, parent_hash=token_hash)
        if error is not None:
            raise error
        assert result is not None
        return result

    def _revoke_device_tokens(self, conn: sqlite3.Connection, device_id: str, now: int) -> None:
        conn.execute("UPDATE mobile_tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL", (now, device_id))

    # ------------------------------------------------------------------ devices

    def list_devices(self, principal: Principal) -> list[dict]:
        with self.db.read() as conn:
            rows = conn.execute(
                """SELECT id, name, model, system_version, created_at, last_seen_at FROM mobile_devices
                   WHERE user_id = ? AND revoked_at IS NULL ORDER BY last_seen_at DESC""",
                (principal.user_id,),
            ).fetchall()
        return [
            {
                "id": row["id"],
                "name": row["name"],
                "model": row["model"],
                "system_version": row["system_version"],
                "created_at": row["created_at"],
                "last_seen_at": row["last_seen_at"],
                "is_current": row["id"] == principal.device_id,
            }
            for row in rows
        ]

    def revoke_device(self, principal: Principal, device_id: str, client_ip: str | None = None) -> None:
        now = self._now()
        with self.db.tx() as conn:
            row = conn.execute(
                "SELECT id FROM mobile_devices WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
                (device_id, principal.user_id),
            ).fetchone()
            if row is None:
                raise not_found("device_not_found", "Device not found")
            conn.execute("UPDATE mobile_devices SET revoked_at = ? WHERE id = ?", (now, device_id))
            self._revoke_device_tokens(conn, device_id, now)
            conn.execute(
                "UPDATE mobile_uploads SET status = 'cancelled', updated_at = ? WHERE device_id = ? AND status = 'active'",
                (now, device_id),
            )
            self.audit(conn, "device.revoked", user_id=principal.user_id, device_id=device_id, client_ip=client_ip)

    def revoke_device_admin(self, device_id: str) -> bool:
        now = self._now()
        with self.db.tx() as conn:
            cursor = conn.execute("UPDATE mobile_devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", (now, device_id))
            self._revoke_device_tokens(conn, device_id, now)
            if cursor.rowcount:
                self.audit(conn, "device.revoked_admin", device_id=device_id)
            return cursor.rowcount > 0

    def list_devices_admin(self, telegram_user_id: int) -> list[dict]:
        with self.db.read() as conn:
            rows = conn.execute(
                """SELECT d.id, d.name, d.model, d.created_at, d.last_seen_at, d.revoked_at FROM mobile_devices d
                   JOIN mobile_users u ON u.id = d.user_id WHERE u.telegram_user_id = ? ORDER BY d.created_at""",
                (telegram_user_id,),
            ).fetchall()
        return [dict(row) for row in rows]
