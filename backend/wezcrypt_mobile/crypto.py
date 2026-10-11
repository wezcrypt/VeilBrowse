"""WZC2 segmented AES-256-GCM container.

WZC2 is used only for objects created through the native-app API. Existing WZC1
objects are never rewritten; they stay readable through the legacy hooks.

Layout (all integers big-endian)::

    magic        4  b"WZC2"
    version      1  0x01
    segment_size 4  plaintext bytes per segment (last segment may be shorter)
    key_id       4  id of the key-encryption key (0xFFFFFFFF = client-held key)
    wrap_nonce  12  nonce used to wrap the data key
    wrapped_key 48  AES-256-GCM(kek, dek, aad=magic|version|segment_size|key_id)
    nonce_prefix 8  random per-object prefix
    plain_size   8  total plaintext length
    --- 89 bytes header ---
    segment[i]      AES-256-GCM(dek, plaintext_i,
                                nonce = nonce_prefix | u32(i),
                                aad   = header | u32(i) | u8(is_final))

Every segment is authenticated together with the full header, its index and a
final-segment flag, which prevents reordering, truncation and splicing. Fixed
size segments make HTTP range requests cheap: only the touched segments are
decrypted.
"""

from __future__ import annotations

import io
import os
import struct
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"WZC2"
VERSION = 1
TAG_SIZE = 16
CLIENT_KEY_ID = 0xFFFFFFFF
_HEADER = struct.Struct(">4sBII12s48s8sQ")
HEADER_SIZE = _HEADER.size  # 89


class WZC2Error(Exception):
    """Raised for malformed, truncated or tampered containers."""


@dataclass(frozen=True)
class KeyRing:
    keys: Mapping[int, bytes]
    active_id: int

    def __post_init__(self) -> None:
        if self.active_id not in self.keys:
            raise ValueError("active key id missing from keyring")
        for key in self.keys.values():
            if len(key) != 32:
                raise ValueError("keyring keys must be 32 bytes")

    def get(self, key_id: int) -> bytes:
        try:
            return self.keys[key_id]
        except KeyError as exc:
            raise WZC2Error(f"unknown key id {key_id}") from exc

    def __repr__(self) -> str:  # never print key material
        return f"KeyRing(ids={sorted(self.keys)}, active_id={self.active_id})"


def _wrap_aad(segment_size: int, key_id: int) -> bytes:
    return MAGIC + bytes([VERSION]) + struct.pack(">II", segment_size, key_id)


def segment_count(plaintext_size: int, segment_size: int) -> int:
    if plaintext_size == 0:
        return 1
    return (plaintext_size + segment_size - 1) // segment_size


def ciphertext_size(plaintext_size: int, segment_size: int) -> int:
    return HEADER_SIZE + plaintext_size + segment_count(plaintext_size, segment_size) * TAG_SIZE


@dataclass(frozen=True)
class Header:
    segment_size: int
    key_id: int
    wrap_nonce: bytes
    wrapped_key: bytes
    nonce_prefix: bytes
    plaintext_size: int

    def pack(self) -> bytes:
        return _HEADER.pack(
            MAGIC,
            VERSION,
            self.segment_size,
            self.key_id,
            self.wrap_nonce,
            self.wrapped_key,
            self.nonce_prefix,
            self.plaintext_size,
        )

    @classmethod
    def unpack(cls, data: bytes) -> "Header":
        if len(data) < HEADER_SIZE:
            raise WZC2Error("truncated header")
        magic, version, segment_size, key_id, wrap_nonce, wrapped_key, nonce_prefix, plaintext_size = _HEADER.unpack(
            data[:HEADER_SIZE]
        )
        if magic != MAGIC:
            raise WZC2Error("not a WZC2 container")
        if version != VERSION:
            raise WZC2Error(f"unsupported WZC2 version {version}")
        if segment_size < 1 or segment_size > 64 * 1024 * 1024:
            raise WZC2Error("invalid segment size")
        return cls(segment_size, key_id, wrap_nonce, wrapped_key, nonce_prefix, plaintext_size)

    @property
    def segments(self) -> int:
        return segment_count(self.plaintext_size, self.segment_size)

    def segment_plain_length(self, index: int) -> int:
        if index < 0 or index >= self.segments:
            raise WZC2Error("segment index out of range")
        if index < self.segments - 1:
            return self.segment_size
        return self.plaintext_size - self.segment_size * (self.segments - 1)

    def segment_offset(self, index: int) -> int:
        return HEADER_SIZE + index * (self.segment_size + TAG_SIZE)


def wrap_key(kek: bytes, dek: bytes, segment_size: int, key_id: int, nonce: bytes | None = None) -> tuple[bytes, bytes]:
    nonce = nonce if nonce is not None else os.urandom(12)
    wrapped = AESGCM(kek).encrypt(nonce, dek, _wrap_aad(segment_size, key_id))
    return nonce, wrapped


def unwrap_key(kek: bytes, header: Header) -> bytes:
    try:
        return AESGCM(kek).decrypt(header.wrap_nonce, header.wrapped_key, _wrap_aad(header.segment_size, header.key_id))
    except InvalidTag as exc:
        raise WZC2Error("data key authentication failed") from exc


def _segment_nonce(prefix: bytes, index: int) -> bytes:
    return prefix + struct.pack(">I", index)


def _segment_aad(header_bytes: bytes, index: int, final: bool) -> bytes:
    return header_bytes + struct.pack(">IB", index, 1 if final else 0)


class SegmentEncryptor:
    """Encrypts a stream of known total size segment by segment."""

    def __init__(
        self,
        kek: bytes,
        key_id: int,
        plaintext_size: int,
        segment_size: int,
        *,
        dek: bytes | None = None,
        wrap_nonce: bytes | None = None,
        nonce_prefix: bytes | None = None,
    ) -> None:
        if plaintext_size < 0:
            raise ValueError("plaintext size must be >= 0")
        self._dek = dek if dek is not None else AESGCM.generate_key(bit_length=256)
        nonce, wrapped = wrap_key(kek, self._dek, segment_size, key_id, wrap_nonce)
        self.header = Header(
            segment_size=segment_size,
            key_id=key_id,
            wrap_nonce=nonce,
            wrapped_key=wrapped,
            nonce_prefix=nonce_prefix if nonce_prefix is not None else os.urandom(8),
            plaintext_size=plaintext_size,
        )
        self.header_bytes = self.header.pack()
        self._aead = AESGCM(self._dek)

    @classmethod
    def resume(cls, kek: bytes, header_bytes: bytes) -> "SegmentEncryptor":
        header = Header.unpack(header_bytes)
        dek = unwrap_key(kek, header)
        instance = cls.__new__(cls)
        instance._dek = dek
        instance.header = header
        instance.header_bytes = header.pack()
        instance._aead = AESGCM(dek)
        return instance

    def encrypt_segment(self, index: int, plaintext: bytes) -> bytes:
        expected = self.header.segment_plain_length(index)
        if len(plaintext) != expected:
            raise WZC2Error(f"segment {index} must be {expected} bytes, got {len(plaintext)}")
        final = index == self.header.segments - 1
        return self._aead.encrypt(
            _segment_nonce(self.header.nonce_prefix, index),
            plaintext,
            _segment_aad(self.header_bytes, index, final),
        )


class SegmentReader:
    """Random-access decryption of a WZC2 container."""

    def __init__(self, stream: BinaryIO, keyring: KeyRing | Mapping[int, bytes]) -> None:
        self._stream = stream
        header_bytes = stream.read(HEADER_SIZE)
        self.header = Header.unpack(header_bytes)
        self._header_bytes = header_bytes
        keys = keyring.keys if isinstance(keyring, KeyRing) else keyring
        if self.header.key_id not in keys:
            raise WZC2Error(f"unknown key id {self.header.key_id}")
        self._aead = AESGCM(unwrap_key(keys[self.header.key_id], self.header))

    @property
    def size(self) -> int:
        return self.header.plaintext_size

    def read_segment(self, index: int) -> bytes:
        header = self.header
        plain_len = header.segment_plain_length(index)
        self._stream.seek(header.segment_offset(index))
        blob = self._stream.read(plain_len + TAG_SIZE)
        if len(blob) != plain_len + TAG_SIZE:
            raise WZC2Error("container is truncated")
        final = index == header.segments - 1
        try:
            return self._aead.decrypt(
                _segment_nonce(header.nonce_prefix, index),
                blob,
                _segment_aad(self._header_bytes, index, final),
            )
        except InvalidTag as exc:
            raise WZC2Error(f"segment {index} failed authentication") from exc

    def iter_range(self, start: int, end_inclusive: int) -> Iterator[bytes]:
        if self.size == 0:
            self.read_segment(0)
            return
        if start < 0 or end_inclusive >= self.size or start > end_inclusive:
            raise WZC2Error("range out of bounds")
        seg = self.header.segment_size
        first, last = start // seg, end_inclusive // seg
        for index in range(first, last + 1):
            data = self.read_segment(index)
            seg_start = index * seg
            lo = max(start - seg_start, 0)
            hi = min(end_inclusive - seg_start + 1, len(data))
            yield data[lo:hi]

    def iter_all(self) -> Iterator[bytes]:
        if self.size == 0:
            self.read_segment(0)
            return
        yield from self.iter_range(0, self.size - 1)


def encrypt_bytes(data: bytes, kek: bytes, key_id: int, segment_size: int = 1024 * 1024, **fixed: bytes) -> bytes:
    encryptor = SegmentEncryptor(kek, key_id, len(data), segment_size, **fixed)
    out = io.BytesIO()
    out.write(encryptor.header_bytes)
    for index in range(encryptor.header.segments):
        chunk = data[index * segment_size : (index + 1) * segment_size]
        out.write(encryptor.encrypt_segment(index, chunk))
    return out.getvalue()


def decrypt_bytes(blob: bytes, keyring: KeyRing | Mapping[int, bytes]) -> bytes:
    reader = SegmentReader(io.BytesIO(blob), keyring)
    if len(blob) != ciphertext_size(reader.size, reader.header.segment_size):
        raise WZC2Error("container length does not match header")
    return b"".join(reader.iter_all())


def encrypt_file(source: Path, destination: Path, kek: bytes, key_id: int, segment_size: int = 1024 * 1024) -> None:
    size = source.stat().st_size
    encryptor = SegmentEncryptor(kek, key_id, size, segment_size)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as out, source.open("rb") as src:
        out.write(encryptor.header_bytes)
        for index in range(encryptor.header.segments):
            chunk = src.read(encryptor.header.segment_plain_length(index))
            out.write(encryptor.encrypt_segment(index, chunk))
        out.flush()
        os.fsync(out.fileno())


def verify_file_length(path: Path) -> Header:
    with path.open("rb") as handle:
        header = Header.unpack(handle.read(HEADER_SIZE))
    actual = path.stat().st_size
    if actual != ciphertext_size(header.plaintext_size, header.segment_size):
        raise WZC2Error("container length does not match header")
    return header
