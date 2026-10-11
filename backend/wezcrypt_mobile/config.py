"""Runtime configuration for the WezCrypt native-app API.

All secrets are read from files referenced by environment variables, never from
the environment value itself, so they do not leak through `ps`, crash dumps or
systemd `show` output.
"""

from __future__ import annotations

import base64
import binascii
import logging
import os
import stat
from dataclasses import dataclass, field
from pathlib import Path

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

logger = logging.getLogger("wezcrypt_mobile.config")

GIB = 1024 * 1024 * 1024
MIB = 1024 * 1024


class ConfigError(RuntimeError):
    """Raised when the service is misconfigured. Never includes secret material."""


def _decode_key_material(text: str, source: str) -> bytes:
    value = text.strip()
    candidates: list[bytes] = []
    if len(value) == 64:
        try:
            candidates.append(bytes.fromhex(value))
        except ValueError:
            pass
    try:
        candidates.append(base64.b64decode(value, validate=True))
    except (binascii.Error, ValueError):
        pass
    try:
        candidates.append(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))
    except (binascii.Error, ValueError):
        pass
    for candidate in candidates:
        if len(candidate) == 32:
            return candidate
    raise ConfigError(f"{source}: key material must be 32 bytes encoded as base64 or hex")


def _check_secret_permissions(path: Path, allow_insecure: bool) -> None:
    mode = path.stat().st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        message = f"secret file {path} is accessible by group/other (mode {oct(mode & 0o777)}); run chmod 600"
        if allow_insecure:
            logger.warning(message)
        else:
            raise ConfigError(message)


def _read_secret_file(path_value: str | None, name: str, allow_insecure: bool) -> str | None:
    if not path_value:
        return None
    path = Path(path_value)
    if not path.is_file():
        raise ConfigError(f"{name} points to a missing file: {path}")
    _check_secret_permissions(path, allow_insecure)
    return path.read_text(encoding="utf-8")


def parse_keyring(text: str, source: str) -> dict[int, bytes]:
    """Parse a keyring file.

    Accepted line formats (blank lines and `#` comments ignored):
        <base64-or-hex-key>            -> key id 1
        <key-id>:<base64-or-hex-key>
    """
    keys: dict[int, bytes] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" in line:
            key_id_text, key_text = line.split(":", 1)
            try:
                key_id = int(key_id_text.strip())
            except ValueError as exc:
                raise ConfigError(f"{source}:{line_number}: invalid key id") from exc
        else:
            key_id, key_text = 1, line
        if not 1 <= key_id < 0xFFFFFFFF:
            raise ConfigError(f"{source}:{line_number}: key id must be between 1 and 4294967294")
        if key_id in keys:
            raise ConfigError(f"{source}:{line_number}: duplicate key id {key_id}")
        keys[key_id] = _decode_key_material(key_text, f"{source}:{line_number}")
    if not keys:
        raise ConfigError(f"{source}: no keys found")
    return keys


def _env_int(name: str, default: int, minimum: int | None = None, maximum: int | None = None) -> int:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
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
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class MobileSettings:
    data_dir: Path
    master_keys: dict[int, bytes] = field(repr=False)
    active_key_id: int
    token_pepper: bytes = field(repr=False)
    internal_secret: str | None = field(default=None, repr=False)
    allowed_telegram_ids: frozenset[int] = frozenset()
    bot_username: str | None = None
    access_ttl: int = 15 * 60
    refresh_ttl: int = 30 * 24 * 3600
    refresh_grace: int = 60
    pairing_ttl: int = 5 * 60
    signature_skew: int = 5 * 60
    max_file_size: int = 20 * GIB
    segment_size: int = 1 * MIB
    chunk_segments: int = 8
    upload_ttl: int = 7 * 24 * 3600
    max_active_uploads_per_device: int = 64
    thumbnail_max_bytes: int = 2 * MIB
    json_body_max_bytes: int = 1 * MIB
    library_page_max: int = 500
    storage_format: str = "wzc2"
    legacy_store_hook: str | None = None
    legacy_open_hook: str | None = None
    legacy_list_hook: str | None = None
    legacy_preview_hook: str | None = None
    legacy_cache_ttl: int = 10 * 60
    legacy_cache_max_bytes: int = 4 * GIB
    trust_proxy_headers: bool = True
    enable_docs: bool = False

    @property
    def db_path(self) -> Path:
        return self.data_dir / "mobile.sqlite3"

    @property
    def storage_dir(self) -> Path:
        return self.data_dir / "objects"

    @property
    def upload_dir(self) -> Path:
        return self.data_dir / "uploads"

    @property
    def legacy_cache_dir(self) -> Path:
        return self.data_dir / "legacy-cache"

    @property
    def chunk_size(self) -> int:
        return self.segment_size * self.chunk_segments

    @property
    def max_chunk_bytes(self) -> int:
        return self.chunk_size

    def validate(self) -> None:
        if self.active_key_id not in self.master_keys:
            raise ConfigError("active key id is not present in the keyring")
        if self.storage_format not in {"wzc2", "legacy"}:
            raise ConfigError("storage format must be 'wzc2' or 'legacy'")
        if self.storage_format == "legacy" and not self.legacy_store_hook:
            raise ConfigError("storage format 'legacy' requires WZC_MOBILE_LEGACY_STORE_HOOK")
        if self.segment_size < 64 * 1024 or self.segment_size > 16 * MIB:
            raise ConfigError("segment size must be between 64 KiB and 16 MiB")
        if self.chunk_segments < 1 or self.chunk_segments > 64:
            raise ConfigError("chunk segments must be between 1 and 64")
        if self.access_ttl < 60 or self.refresh_ttl < self.access_ttl:
            raise ConfigError("token lifetimes are inconsistent")

    def ensure_directories(self) -> None:
        for directory in (self.data_dir, self.storage_dir, self.upload_dir, self.legacy_cache_dir):
            directory.mkdir(parents=True, exist_ok=True)
            os.chmod(directory, 0o700)

    @classmethod
    def from_env(cls) -> "MobileSettings":
        allow_insecure = _env_bool("WZC_MOBILE_ALLOW_INSECURE_KEY_PERMS", False)
        keyring_text = _read_secret_file(os.environ.get("WZC_MOBILE_MASTER_KEY_FILE"), "WZC_MOBILE_MASTER_KEY_FILE", allow_insecure)
        if keyring_text is None:
            raise ConfigError("WZC_MOBILE_MASTER_KEY_FILE is required (generate one with `python -m wezcrypt_mobile generate-key`)")
        master_keys = parse_keyring(keyring_text, "WZC_MOBILE_MASTER_KEY_FILE")
        active_key_id = _env_int("WZC_MOBILE_ACTIVE_KEY_ID", max(master_keys), minimum=1)

        pepper_text = _read_secret_file(os.environ.get("WZC_MOBILE_TOKEN_PEPPER_FILE"), "WZC_MOBILE_TOKEN_PEPPER_FILE", allow_insecure)
        if pepper_text is not None:
            token_pepper = _decode_key_material(pepper_text, "WZC_MOBILE_TOKEN_PEPPER_FILE")
        else:
            token_pepper = derive_subkey(master_keys[min(master_keys)], b"wzc-mobile/token-pepper/v1")

        internal_text = _read_secret_file(os.environ.get("WZC_MOBILE_INTERNAL_SECRET_FILE"), "WZC_MOBILE_INTERNAL_SECRET_FILE", allow_insecure)
        internal_secret = internal_text.strip() if internal_text else None
        if internal_secret is not None and len(internal_secret) < 32:
            raise ConfigError("WZC_MOBILE_INTERNAL_SECRET_FILE must contain at least 32 characters")

        allowed_raw = os.environ.get("WZC_MOBILE_ALLOWED_TELEGRAM_IDS", "")
        allowed: set[int] = set()
        for part in allowed_raw.replace(";", ",").split(","):
            part = part.strip()
            if not part:
                continue
            try:
                allowed.add(int(part))
            except ValueError as exc:
                raise ConfigError("WZC_MOBILE_ALLOWED_TELEGRAM_IDS must be a comma separated list of integers") from exc

        bot_username = (os.environ.get("WZC_MOBILE_BOT_USERNAME") or "").strip().lstrip("@") or None

        settings = cls(
            data_dir=Path(os.environ.get("WZC_MOBILE_DATA_DIR", "/var/lib/wezcrypt-mobile")),
            master_keys=master_keys,
            active_key_id=active_key_id,
            token_pepper=token_pepper,
            internal_secret=internal_secret,
            allowed_telegram_ids=frozenset(allowed),
            bot_username=bot_username,
            access_ttl=_env_int("WZC_MOBILE_ACCESS_TTL", 15 * 60, minimum=60, maximum=24 * 3600),
            refresh_ttl=_env_int("WZC_MOBILE_REFRESH_TTL", 30 * 24 * 3600, minimum=3600),
            pairing_ttl=_env_int("WZC_MOBILE_PAIRING_TTL", 5 * 60, minimum=60, maximum=30 * 60),
            max_file_size=_env_int("WZC_MOBILE_MAX_FILE_SIZE", 20 * GIB, minimum=1),
            segment_size=_env_int("WZC_MOBILE_SEGMENT_SIZE", 1 * MIB),
            chunk_segments=_env_int("WZC_MOBILE_CHUNK_SEGMENTS", 8),
            upload_ttl=_env_int("WZC_MOBILE_UPLOAD_TTL", 7 * 24 * 3600, minimum=3600),
            max_active_uploads_per_device=_env_int("WZC_MOBILE_MAX_ACTIVE_UPLOADS", 64, minimum=1),
            storage_format=os.environ.get("WZC_MOBILE_STORAGE_FORMAT", "wzc2").strip().lower(),
            legacy_store_hook=os.environ.get("WZC_MOBILE_LEGACY_STORE_HOOK") or None,
            legacy_open_hook=os.environ.get("WZC_MOBILE_LEGACY_OPEN_HOOK") or None,
            legacy_list_hook=os.environ.get("WZC_MOBILE_LEGACY_LIST_HOOK") or None,
            legacy_preview_hook=os.environ.get("WZC_MOBILE_LEGACY_PREVIEW_HOOK") or None,
            legacy_cache_ttl=_env_int("WZC_MOBILE_LEGACY_CACHE_TTL", 10 * 60, minimum=30),
            legacy_cache_max_bytes=_env_int("WZC_MOBILE_LEGACY_CACHE_MAX_BYTES", 4 * GIB, minimum=MIB),
            trust_proxy_headers=_env_bool("WZC_MOBILE_TRUST_PROXY", True),
            enable_docs=_env_bool("WZC_MOBILE_ENABLE_DOCS", False),
        )
        settings.validate()
        return settings


def derive_subkey(master: bytes, info: bytes) -> bytes:
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=None, info=info).derive(master)
