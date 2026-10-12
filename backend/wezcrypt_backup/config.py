"""Configuration for the WezCrypt encrypted backup service.

The service only ever stores ciphertext produced on the iPhone. It holds no
encryption keys. The only server-side secret is the token pepper (used to hash
session tokens and API keys at rest), read from a file referenced by an
environment variable.
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
import re
import secrets
import stat
from dataclasses import dataclass, field
from pathlib import Path

logger = logging.getLogger("wezcrypt_backup.config")

MIB = 1024 * 1024
GIB = 1024 * MIB

USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{1,31}$")
COLLECTION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")


class ConfigError(RuntimeError):
    """Misconfiguration. Messages never contain secret material."""


def _env_int(name: str, default: int, minimum: int | None = None, maximum: int | None = None) -> int:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer") from exc
    if minimum is not None and value < minimum:
        raise ConfigError(f"{name} must be >= {minimum}")
    if maximum is not None and value > maximum:
        raise ConfigError(f"{name} must be <= {maximum}")
    return value


def _env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def read_secret_file(path: Path, allow_insecure: bool = False) -> bytes:
    if not path.is_file():
        raise ConfigError(f"secret file not found: {path}")
    mode = path.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        message = f"secret file {path} must not be accessible by group/other (chmod 600)"
        if not allow_insecure:
            raise ConfigError(message)
        logger.warning(message)
    text = path.read_text(encoding="utf-8").strip()
    try:
        value = base64.b64decode(text, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ConfigError(f"{path}: expected base64") from exc
    if len(value) < 32:
        raise ConfigError(f"{path}: secret must be at least 32 bytes")
    return value


def generate_secret_text() -> str:
    return base64.b64encode(secrets.token_bytes(32)).decode()


@dataclass(frozen=True)
class Settings:
    storage_root: Path
    state_dir: Path
    token_pepper: bytes = field(repr=False)
    token_ttl: int = 30 * 24 * 3600
    max_object_size: int = 64 * GIB
    max_chunk_size: int = 32 * MIB
    max_chunks_per_object: int = 200_000
    # Open upload sessions per user. The iOS client opens a session only when it
    # starts sending an object, so it needs about as many as its upload concurrency.
    max_active_uploads_per_user: int = 256
    # Chunk PUT requests being received at the same time per user (fair share of
    # disk and CPU between users and devices). Excess requests get 429 + Retry-After.
    max_inflight_chunks_per_user: int = 8
    # Sessions with no received chunk and no activity for this long are treated as
    # abandoned and reclaimed when a user reaches the session limit.
    abandoned_upload_seconds: int = 15 * 60
    upload_ttl: int = 7 * 24 * 3600
    json_body_max_bytes: int = 4 * MIB
    manifest_max_bytes: int = 256 * 1024
    page_max: int = 500
    min_free_bytes: int = 2 * GIB
    login_attempts_per_window: int = 8
    login_window_seconds: int = 15 * 60
    trust_proxy_headers: bool = True
    enable_docs: bool = False

    @property
    def db_path(self) -> Path:
        return self.state_dir / "backup.sqlite3"

    @property
    def upload_dir(self) -> Path:
        return self.storage_root / ".uploads"

    def validate(self) -> None:
        if self.max_chunk_size < 64 * 1024:
            raise ConfigError("max chunk size must be at least 64 KiB")
        if self.token_ttl < 3600:
            raise ConfigError("token ttl must be at least one hour")
        if len(self.token_pepper) < 32:
            raise ConfigError("token pepper too short")

    def ensure_directories(self) -> None:
        for directory in (self.storage_root, self.state_dir, self.upload_dir):
            directory.mkdir(parents=True, exist_ok=True)
            os.chmod(directory, 0o700)

    @classmethod
    def from_env(cls) -> "Settings":
        allow_insecure = _env_bool("WZC_BACKUP_ALLOW_INSECURE_SECRET_PERMS", False)
        pepper_path = os.environ.get("WZC_BACKUP_TOKEN_PEPPER_FILE")
        if not pepper_path:
            raise ConfigError("WZC_BACKUP_TOKEN_PEPPER_FILE is required (python -m wezcrypt_backup generate-pepper PATH)")
        settings = cls(
            storage_root=Path(os.environ.get("WZC_BACKUP_STORAGE_ROOT", "/srv/wezcrypt/iphone-backups")),
            state_dir=Path(os.environ.get("WZC_BACKUP_STATE_DIR", "/var/lib/wezcrypt-backup")),
            token_pepper=read_secret_file(Path(pepper_path), allow_insecure),
            token_ttl=_env_int("WZC_BACKUP_TOKEN_TTL", 30 * 24 * 3600, minimum=3600),
            max_object_size=_env_int("WZC_BACKUP_MAX_OBJECT_SIZE", 64 * GIB, minimum=1),
            max_chunk_size=_env_int("WZC_BACKUP_MAX_CHUNK_SIZE", 32 * MIB, minimum=64 * 1024, maximum=256 * MIB),
            upload_ttl=_env_int("WZC_BACKUP_UPLOAD_TTL", 7 * 24 * 3600, minimum=3600),
            max_active_uploads_per_user=_env_int("WZC_BACKUP_MAX_ACTIVE_UPLOADS", 256, minimum=4, maximum=10_000),
            max_inflight_chunks_per_user=_env_int("WZC_BACKUP_MAX_INFLIGHT_CHUNKS", 8, minimum=1, maximum=256),
            abandoned_upload_seconds=_env_int("WZC_BACKUP_ABANDONED_UPLOAD_SECONDS", 15 * 60, minimum=60),
            min_free_bytes=_env_int("WZC_BACKUP_MIN_FREE_BYTES", 2 * GIB, minimum=0),
            trust_proxy_headers=_env_bool("WZC_BACKUP_TRUST_PROXY", True),
            enable_docs=_env_bool("WZC_BACKUP_ENABLE_DOCS", False),
        )
        settings.validate()
        return settings
