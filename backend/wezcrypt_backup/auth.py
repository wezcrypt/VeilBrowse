"""Users, password login, session tokens and API keys (no Telegram involvement)."""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from collections.abc import Callable
from dataclasses import dataclass

from .config import USERNAME_RE, Settings
from .db import Database
from .errors import APIError, bad_request, unauthorized
from .ratelimit import SlidingWindowLimiter

SESSION_PREFIX = "wzt_"
API_KEY_PREFIX = "wzk_"
_SCRYPT_N, _SCRYPT_R, _SCRYPT_P = 2**15, 8, 1


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32, maxmem=128 * 1024 * 1024)
    return f"scrypt${_SCRYPT_N}${_SCRYPT_R}${_SCRYPT_P}${salt.hex()}${digest.hex()}"


def verify_password(password: str, encoded: str | None) -> bool:
    if not encoded:
        # Burn comparable CPU so missing users are not distinguishable by timing.
        hashlib.scrypt(b"x", salt=b"0" * 16, n=_SCRYPT_N, r=_SCRYPT_R, p=_SCRYPT_P, dklen=32, maxmem=128 * 1024 * 1024)
        return False
    try:
        scheme, n, r, p, salt_hex, digest_hex = encoded.split("$")
        if scheme != "scrypt":
            return False
        digest = hashlib.scrypt(
            password.encode("utf-8"), salt=bytes.fromhex(salt_hex), n=int(n), r=int(r), p=int(p), dklen=32, maxmem=128 * 1024 * 1024
        )
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(digest.hex(), digest_hex)


def validate_password_strength(password: str) -> None:
    if len(password) < 12:
        raise ValueError("password must be at least 12 characters")
    if len(password) > 1024:
        raise ValueError("password is too long")


@dataclass(frozen=True)
class Principal:
    user_id: int
    username: str
    token_kind: str
    token_hash: str


class AuthService:
    def __init__(self, db: Database, settings: Settings, clock: Callable[[], float] = time.time) -> None:
        self.db = db
        self.settings = settings
        self.clock = clock
        self.login_limiter = SlidingWindowLimiter(settings.login_attempts_per_window, settings.login_window_seconds)

    def _now(self) -> int:
        return int(self.clock())

    def _hash(self, token: str) -> str:
        return hmac.new(self.settings.token_pepper, token.encode("utf-8"), hashlib.sha256).hexdigest()

    def audit(self, conn, event: str, user_id: int | None = None, detail: str | None = None, client_ip: str | None = None) -> None:
        conn.execute(
            "INSERT INTO audit(user_id, event, detail, client_ip, created_at) VALUES (?,?,?,?,?)",
            (user_id, event, detail, client_ip, self._now()),
        )

    # ---------------------------------------------------------------- admin

    def create_user(self, username: str, password: str | None, quota_bytes: int | None = None) -> int:
        if not USERNAME_RE.match(username):
            raise ValueError("username must be 2-32 chars: lowercase letters, digits, _ . -")
        password_hash = None
        if password is not None:
            validate_password_strength(password)
            password_hash = hash_password(password)
        with self.db.tx() as conn:
            if conn.execute("SELECT 1 FROM users WHERE username = ?", (username,)).fetchone():
                raise ValueError("user already exists")
            cursor = conn.execute(
                "INSERT INTO users(username, password_hash, quota_bytes, created_at) VALUES (?,?,?,?)",
                (username, password_hash, quota_bytes, self._now()),
            )
            self.audit(conn, "user.created", cursor.lastrowid)
            return int(cursor.lastrowid)

    def set_password(self, username: str, password: str) -> None:
        validate_password_strength(password)
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
            if row is None:
                raise ValueError("no such user")
            conn.execute("UPDATE users SET password_hash = ? WHERE id = ?", (hash_password(password), row["id"]))
            conn.execute("UPDATE tokens SET revoked_at = ? WHERE user_id = ? AND kind = 'session' AND revoked_at IS NULL", (self._now(), row["id"]))
            self.audit(conn, "user.password_changed", row["id"])

    def set_disabled(self, username: str, disabled: bool) -> None:
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
            if row is None:
                raise ValueError("no such user")
            conn.execute("UPDATE users SET disabled = ? WHERE id = ?", (int(disabled), row["id"]))
            if disabled:
                conn.execute("UPDATE tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL", (self._now(), row["id"]))

    def set_quota(self, username: str, quota_bytes: int | None) -> None:
        with self.db.tx() as conn:
            if conn.execute("UPDATE users SET quota_bytes = ? WHERE username = ?", (quota_bytes, username)).rowcount == 0:
                raise ValueError("no such user")

    def create_api_key(self, username: str, label: str) -> str:
        key = API_KEY_PREFIX + secrets.token_urlsafe(32)
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM users WHERE username = ? AND disabled = 0", (username,)).fetchone()
            if row is None:
                raise ValueError("no such active user")
            conn.execute(
                "INSERT INTO tokens(token_hash, user_id, kind, label, created_at) VALUES (?,?,?,?,?)",
                (self._hash(key), row["id"], "api_key", label[:64], self._now()),
            )
            self.audit(conn, "api_key.created", row["id"], label[:64])
        return key

    def revoke_api_keys(self, username: str, label: str | None = None) -> int:
        with self.db.tx() as conn:
            row = conn.execute("SELECT id FROM users WHERE username = ?", (username,)).fetchone()
            if row is None:
                raise ValueError("no such user")
            sql = "UPDATE tokens SET revoked_at = ? WHERE user_id = ? AND kind = 'api_key' AND revoked_at IS NULL"
            params: list = [self._now(), row["id"]]
            if label:
                sql += " AND label = ?"
                params.append(label)
            return conn.execute(sql, params).rowcount

    def list_users(self) -> list[dict]:
        with self.db.read() as conn:
            rows = conn.execute(
                """SELECT u.username, u.disabled, u.quota_bytes, u.created_at,
                          (SELECT COALESCE(SUM(size_bytes),0) FROM objects o WHERE o.user_id = u.id) AS used_bytes,
                          (SELECT COUNT(*) FROM items i WHERE i.user_id = u.id) AS items
                   FROM users u ORDER BY u.username"""
            ).fetchall()
        return [dict(row) for row in rows]

    # ---------------------------------------------------------------- login

    def login(self, username: str, password: str, client_ip: str | None, device_label: str) -> dict:
        key = f"{username.lower()}|{client_ip}"
        # Only failed attempts count toward the limit; a successful login clears
        # them, so legitimate clients that sign in often are never locked out.
        wait = self.login_limiter.blocked(key)
        if wait:
            raise APIError(429, "rate_limited", "Too many login attempts. Try again later.", headers={"Retry-After": str(wait)})
        with self.db.read() as conn:
            row = conn.execute("SELECT id, username, password_hash, disabled FROM users WHERE username = ?", (username.lower(),)).fetchone()
        valid = verify_password(password, row["password_hash"] if row else None)
        if row is None or not valid or row["disabled"]:
            with self.db.tx() as conn:
                self.audit(conn, "login.failed", row["id"] if row else None, None, client_ip)
            self.login_limiter.record(key)
            raise unauthorized("invalid_credentials", "Incorrect username or password")
        self.login_limiter.reset(key)
        token = SESSION_PREFIX + secrets.token_urlsafe(32)
        now = self._now()
        expires = now + self.settings.token_ttl
        with self.db.tx() as conn:
            conn.execute(
                "INSERT INTO tokens(token_hash, user_id, kind, label, created_at, expires_at) VALUES (?,?,?,?,?,?)",
                (self._hash(token), row["id"], "session", device_label[:64], now, expires),
            )
            conn.execute("DELETE FROM tokens WHERE kind = 'session' AND expires_at < ?", (now - 86400,))
            self.audit(conn, "login.ok", row["id"], device_label[:64], client_ip)
        return {"token": token, "token_type": "session", "expires_at": expires, "username": row["username"]}

    def logout(self, principal: Principal) -> None:
        if principal.token_kind != "session":
            raise bad_request("not_a_session", "API keys are revoked with the server CLI")
        with self.db.tx() as conn:
            conn.execute("UPDATE tokens SET revoked_at = ? WHERE token_hash = ?", (self._now(), principal.token_hash))

    def authenticate(self, token: str) -> Principal:
        if not (token.startswith(SESSION_PREFIX) or token.startswith(API_KEY_PREFIX)) or len(token) > 128:
            raise unauthorized("invalid_token", "Invalid credentials")
        token_hash = self._hash(token)
        now = self._now()
        with self.db.read() as conn:
            row = conn.execute(
                """SELECT t.kind, t.expires_at, t.revoked_at, t.last_used_at, u.id AS user_id, u.username, u.disabled
                   FROM tokens t JOIN users u ON u.id = t.user_id WHERE t.token_hash = ?""",
                (token_hash,),
            ).fetchone()
        if row is None or row["revoked_at"] is not None or row["disabled"]:
            raise unauthorized("invalid_token", "Invalid credentials")
        if row["expires_at"] is not None and row["expires_at"] <= now:
            raise unauthorized("token_expired", "Session expired; sign in again")
        if row["last_used_at"] is None or now - row["last_used_at"] > 300:
            with self.db.tx() as conn:
                conn.execute("UPDATE tokens SET last_used_at = ? WHERE token_hash = ?", (now, token_hash))
        return Principal(int(row["user_id"]), row["username"], row["kind"], token_hash)
