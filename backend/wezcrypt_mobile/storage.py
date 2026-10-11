"""Encrypted object storage for native-app uploads (WZC2 containers)."""

from __future__ import annotations

import os
import re
from collections.abc import Iterator
from pathlib import Path

from .config import MobileSettings
from .crypto import KeyRing, SegmentReader, WZC2Error, decrypt_bytes, encrypt_bytes

_REF_RE = re.compile(r"^(media|thumbs)/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]{32}\.wzc2$")
_ID_RE = re.compile(r"^[0-9a-f]{32}$")


class ObjectStore:
    def __init__(self, settings: MobileSettings) -> None:
        self.settings = settings
        self.root = settings.storage_dir
        self.upload_dir = settings.upload_dir
        self.keyring = KeyRing(settings.master_keys, settings.active_key_id)

    @property
    def active_kek(self) -> tuple[int, bytes]:
        return self.keyring.active_id, self.keyring.get(self.keyring.active_id)

    @staticmethod
    def new_ref(object_id: str, kind: str = "media") -> str:
        if not _ID_RE.match(object_id) or kind not in {"media", "thumbs"}:
            raise ValueError("invalid object id")
        return f"{kind}/{object_id[:2]}/{object_id[2:4]}/{object_id}.wzc2"

    def path_for(self, ref: str) -> Path:
        if not _REF_RE.match(ref):
            raise WZC2Error("invalid object reference")
        return self.root / ref

    def part_path(self, upload_id: str) -> Path:
        if not _ID_RE.match(upload_id):
            raise ValueError("invalid upload id")
        return self.upload_dir / f"{upload_id}.wzc2.part"

    def commit_part(self, upload_id: str, ref: str) -> Path:
        target = self.path_for(ref)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.replace(self.part_path(upload_id), target)
        dir_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        return target

    def iter_range(self, ref: str, start: int, end_inclusive: int) -> Iterator[bytes]:
        with self.path_for(ref).open("rb") as handle:
            reader = SegmentReader(handle, self.keyring)
            yield from reader.iter_range(start, end_inclusive)

    def plaintext_size(self, ref: str) -> int:
        with self.path_for(ref).open("rb") as handle:
            return SegmentReader(handle, self.keyring).size

    def write_small(self, ref: str, data: bytes) -> None:
        key_id, kek = self.active_kek
        blob = encrypt_bytes(data, kek, key_id, segment_size=self.settings.segment_size)
        target = self.path_for(ref)
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        temp = target.with_name(target.name + ".tmp")
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as out:
            out.write(blob)
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, target)

    def read_small(self, ref: str) -> bytes:
        return decrypt_bytes(self.path_for(ref).read_bytes(), self.keyring)

    def delete(self, ref: str | None) -> None:
        if not ref:
            return
        try:
            self.path_for(ref).unlink()
        except FileNotFoundError:
            pass
