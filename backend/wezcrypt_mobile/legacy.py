"""Bridge to the existing WZC1 studio storage.

The native-app API never re-implements or rewrites the WZC1 format. Instead it
calls functions that already exist in the current studio code base, configured
as ``module:function`` import paths:

``WZC_MOBILE_LEGACY_OPEN_HOOK``
    ``fn(file_ref: str, telegram_user_id: int, destination: pathlib.Path) -> None``
    Decrypts an existing WZC1 object into ``destination`` (created 0600 by us).

``WZC_MOBILE_LEGACY_PREVIEW_HOOK``
    ``fn(file_ref: str, telegram_user_id: int) -> bytes | None`` (JPEG/PNG bytes)

``WZC_MOBILE_LEGACY_LIST_HOOK``
    ``fn(telegram_user_id: int) -> Iterable[dict]`` with keys ``file_ref``,
    ``filename``, ``mime_type``, ``size_bytes``, ``sha256`` (optional),
    ``taken_at`` (epoch seconds, optional).

``WZC_MOBILE_LEGACY_STORE_HOOK`` (only when ``WZC_MOBILE_STORAGE_FORMAT=legacy``)
    ``fn(plaintext_path: pathlib.Path, telegram_user_id: int, filename: str, mime_type: str) -> str``
    Encrypts with the existing WZC1 code and returns its file reference.
"""

from __future__ import annotations

import hashlib
import importlib
import logging
import os
import threading
import time
from collections.abc import Callable, Iterable
from pathlib import Path

from .config import MobileSettings
from .errors import APIError

logger = logging.getLogger("wezcrypt_mobile.legacy")


def load_hook(spec: str | None) -> Callable | None:
    if not spec:
        return None
    module_name, sep, attr = spec.partition(":")
    if not sep or not module_name or not attr:
        raise ValueError(f"hook must look like 'package.module:function', got {spec!r}")
    module = importlib.import_module(module_name)
    target = module
    for part in attr.split("."):
        target = getattr(target, part)
    if not callable(target):
        raise ValueError(f"hook {spec!r} is not callable")
    return target


class LegacyBridge:
    def __init__(self, settings: MobileSettings) -> None:
        self.settings = settings
        self.cache_dir = settings.legacy_cache_dir
        self._store = load_hook(settings.legacy_store_hook)
        self._open = load_hook(settings.legacy_open_hook)
        self._list = load_hook(settings.legacy_list_hook)
        self._preview = load_hook(settings.legacy_preview_hook)
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()

    @property
    def can_store(self) -> bool:
        return self._store is not None

    @property
    def can_open(self) -> bool:
        return self._open is not None

    @property
    def can_list(self) -> bool:
        return self._list is not None

    def store(self, plaintext_path: Path, telegram_user_id: int, filename: str, mime_type: str) -> str:
        if self._store is None:
            raise APIError(500, "legacy_unavailable", "Legacy storage hook is not configured")
        ref = self._store(plaintext_path, telegram_user_id, filename, mime_type)
        if not isinstance(ref, str) or not ref:
            raise APIError(500, "legacy_store_failed", "Legacy storage hook returned an invalid reference")
        return ref

    def _lock_for(self, key: str) -> threading.Lock:
        with self._locks_guard:
            return self._locks.setdefault(key, threading.Lock())

    def plaintext_path(self, file_ref: str, telegram_user_id: int) -> Path:
        """Returns a short-lived decrypted copy (0600) for range serving."""
        if self._open is None:
            raise APIError(501, "legacy_unavailable", "Legacy media is not readable from the native app on this server")
        key = hashlib.sha256(f"{telegram_user_id}:{file_ref}".encode()).hexdigest()
        path = self.cache_dir / f"{key}.plain"
        with self._lock_for(key):
            if path.exists() and time.time() - path.stat().st_mtime < self.settings.legacy_cache_ttl:
                os.utime(path)
                return path
            temp = self.cache_dir / f"{key}.{os.getpid()}.tmp"
            fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.close(fd)
            try:
                self._open(file_ref, telegram_user_id, temp)
                os.replace(temp, path)
            except Exception:
                temp.unlink(missing_ok=True)
                logger.exception("legacy open hook failed")
                raise APIError(502, "legacy_open_failed", "Could not open legacy media")
        self.purge_cache()
        return path

    def preview(self, file_ref: str, telegram_user_id: int) -> bytes | None:
        if self._preview is None:
            return None
        try:
            data = self._preview(file_ref, telegram_user_id)
        except Exception:
            logger.exception("legacy preview hook failed")
            return None
        return data if isinstance(data, bytes | bytearray) and data else None

    def list_files(self, telegram_user_id: int) -> Iterable[dict]:
        if self._list is None:
            raise APIError(501, "legacy_unavailable", "Legacy list hook is not configured")
        return self._list(telegram_user_id)

    def purge_cache(self) -> int:
        removed = 0
        now = time.time()
        entries = []
        for path in self.cache_dir.glob("*.plain"):
            try:
                stat = path.stat()
            except FileNotFoundError:
                continue
            if now - stat.st_mtime >= self.settings.legacy_cache_ttl:
                path.unlink(missing_ok=True)
                removed += 1
            else:
                entries.append((stat.st_mtime, stat.st_size, path))
        total = sum(size for _, size, _ in entries)
        for _, size, path in sorted(entries):
            if total <= self.settings.legacy_cache_max_bytes:
                break
            path.unlink(missing_ok=True)
            total -= size
            removed += 1
        for path in self.cache_dir.glob("*.tmp"):
            try:
                if now - path.stat().st_mtime > 3600:
                    path.unlink(missing_ok=True)
            except FileNotFoundError:
                pass
        return removed
