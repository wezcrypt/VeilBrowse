"""Reference implementation of the WZCE v1 client-side encryption format.

This module is NOT used by the server (the server never holds keys). It exists
so the format is auditable, so tests can act as a client, and so backups can be
restored on a desktop with only the recovery key (see wezcrypt_restore.py).
The Swift implementation in the iOS app is verified against it byte-for-byte.

Format (all integers big-endian), see SECURITY.md:

    off  len  field
    0    4    magic "WZCE"
    4    1    version = 1
    5    1    algorithm = 1 (AES-256-GCM)
    6    2    flags = 0
    8    4    segment_size (plaintext bytes per segment)
    12   8    plaintext_size
    20   16   object_id (random; binds ciphertext to its server object/item)
    36   8    nonce_prefix (random)
    44   12   key_nonce (random)
    56   48   wrapped data key = AES-256-GCM(KEK, DEK, key_nonce, aad=header[0:44])
    --- 104 bytes ---
    segment i = AES-256-GCM(DEK, plaintext_i, nonce = nonce_prefix || u32(i),
                            aad = header[0:104] || u32(i) || u8(is_final))
"""

from __future__ import annotations

import hashlib
import hmac
import io
import os
import struct
from collections.abc import Iterable
from typing import BinaryIO

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAGIC = b"WZCE"
VERSION = 1
ALGORITHM = 1
HEADER_SIZE = 104
TAG = 16
_PREFIX = struct.Struct(">4sBBHIQ16s8s")  # 44 bytes
VAULT_SALT = b"WezCrypt-Vault-v1"
CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


class WZCEError(Exception):
    pass


# ------------------------------------------------------------------- keys


def derive(recovery_key: bytes, label: str) -> bytes:
    if len(recovery_key) != 32:
        raise WZCEError("recovery key must be 32 bytes")
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=VAULT_SALT, info=label.encode()).derive(recovery_key)


class VaultKeys:
    def __init__(self, recovery_key: bytes) -> None:
        self.file_wrap = derive(recovery_key, "wzce/file-wrap")
        self.dedup = derive(recovery_key, "wzce/dedup")
        self._fingerprint = derive(recovery_key, "wzce/fingerprint")

    @property
    def fingerprint(self) -> str:
        return hmac.new(self._fingerprint, b"WezCrypt vault fingerprint v1", hashlib.sha256).hexdigest()

    def content_tag(self, kind: str, resources: Iterable[tuple[str, str]]) -> str:
        """resources: (role, plaintext sha256 hex), thumbnails excluded."""
        body = ",".join(f"{role}:{sha}" for role, sha in sorted(resources))
        return hmac.new(self.dedup, f"v1|{kind}|{body}".encode(), hashlib.sha256).hexdigest()


def format_recovery_key(key: bytes) -> str:
    payload = key + hashlib.sha256(key).digest()[:2]
    bits = "".join(f"{b:08b}" for b in payload)
    bits += "0" * (-len(bits) % 5)
    text = "".join(CROCKFORD[int(bits[i : i + 5], 2)] for i in range(0, len(bits), 5))
    return "-".join(text[i : i + 5] for i in range(0, len(text), 5))


def parse_recovery_key(text: str) -> bytes:
    cleaned = text.upper().replace("O", "0").replace("I", "1").replace("L", "1")
    cleaned = "".join(ch for ch in cleaned if ch not in "- \t\n")
    try:
        bits = "".join(f"{CROCKFORD.index(ch):05b}" for ch in cleaned)
    except ValueError as exc:
        raise WZCEError("invalid character in recovery key") from exc
    data = bytes(int(bits[i : i + 8], 2) for i in range(0, len(bits) - len(bits) % 8, 8))
    if len(data) != 34:
        raise WZCEError("recovery key has the wrong length")
    key, check = data[:32], data[32:]
    if hashlib.sha256(key).digest()[:2] != check:
        raise WZCEError("recovery key checksum mismatch (typo?)")
    return key


# --------------------------------------------------------------- containers


def segment_count(size: int, segment_size: int) -> int:
    return 1 if size == 0 else (size + segment_size - 1) // segment_size


def ciphertext_size(size: int, segment_size: int) -> int:
    return HEADER_SIZE + size + segment_count(size, segment_size) * TAG


class Encryptor:
    def __init__(self, kek: bytes, object_id: bytes, plaintext_size: int, segment_size: int, *, dek: bytes | None = None,
                 nonce_prefix: bytes | None = None, key_nonce: bytes | None = None) -> None:
        if len(object_id) != 16:
            raise WZCEError("object_id must be 16 bytes")
        self.segment_size = segment_size
        self.plaintext_size = plaintext_size
        self.segments = segment_count(plaintext_size, segment_size)
        dek = dek or AESGCM.generate_key(bit_length=256)
        nonce_prefix = nonce_prefix or os.urandom(8)
        key_nonce = key_nonce or os.urandom(12)
        prefix = _PREFIX.pack(MAGIC, VERSION, ALGORITHM, 0, segment_size, plaintext_size, object_id, nonce_prefix)
        wrapped = AESGCM(kek).encrypt(key_nonce, dek, prefix)
        self.header = prefix + key_nonce + wrapped
        assert len(self.header) == HEADER_SIZE
        self._nonce_prefix = nonce_prefix
        self._aead = AESGCM(dek)

    def segment(self, index: int, plaintext: bytes) -> bytes:
        expected = self.segment_size if index < self.segments - 1 else self.plaintext_size - self.segment_size * (self.segments - 1)
        if len(plaintext) != expected:
            raise WZCEError(f"segment {index} must be {expected} bytes")
        final = index == self.segments - 1
        return self._aead.encrypt(self._nonce_prefix + struct.pack(">I", index), plaintext, self.header + struct.pack(">IB", index, int(final)))


class Decryptor:
    def __init__(self, kek: bytes, header: bytes, expected_object_id: bytes | None = None) -> None:
        if len(header) < HEADER_SIZE:
            raise WZCEError("truncated header")
        magic, version, algorithm, _flags, segment_size, size, object_id, nonce_prefix = _PREFIX.unpack(header[:44])
        if magic != MAGIC or version != VERSION or algorithm != ALGORITHM:
            raise WZCEError("not a WZCE v1 container")
        if segment_size < 1:
            raise WZCEError("invalid segment size")
        if expected_object_id is not None and not hmac.compare_digest(object_id, expected_object_id):
            raise WZCEError("container belongs to a different object")
        try:
            dek = AESGCM(kek).decrypt(header[44:56], header[56:104], header[:44])
        except InvalidTag as exc:
            raise WZCEError("wrong key or corrupted header") from exc
        self.header = header[:HEADER_SIZE]
        self.segment_size = segment_size
        self.plaintext_size = size
        self.object_id = object_id
        self.segments = segment_count(size, segment_size)
        self._nonce_prefix = nonce_prefix
        self._aead = AESGCM(dek)

    def segment(self, index: int, ciphertext: bytes) -> bytes:
        final = index == self.segments - 1
        try:
            return self._aead.decrypt(self._nonce_prefix + struct.pack(">I", index), ciphertext, self.header + struct.pack(">IB", index, int(final)))
        except InvalidTag as exc:
            raise WZCEError(f"segment {index} is corrupted or out of order") from exc


def encrypt_stream(src: BinaryIO, dst: BinaryIO, kek: bytes, object_id: bytes, size: int, segment_size: int = 4 * 1024 * 1024) -> str:
    """Returns the plaintext SHA-256 hex."""
    enc = Encryptor(kek, object_id, size, segment_size)
    digest = hashlib.sha256()
    dst.write(enc.header)
    for index in range(enc.segments):
        length = segment_size if index < enc.segments - 1 else size - segment_size * (enc.segments - 1)
        block = src.read(length)
        if len(block) != length:
            raise WZCEError("source shorter than declared size")
        digest.update(block)
        dst.write(enc.segment(index, block))
    return digest.hexdigest()


def decrypt_stream(src: BinaryIO, dst: BinaryIO, kek: bytes, expected_object_id: bytes | None = None) -> str:
    """Decrypts and authenticates every segment; returns the plaintext SHA-256 hex."""
    dec = Decryptor(kek, src.read(HEADER_SIZE), expected_object_id)
    digest = hashlib.sha256()
    for index in range(dec.segments):
        length = dec.segment_size if index < dec.segments - 1 else dec.plaintext_size - dec.segment_size * (dec.segments - 1)
        blob = src.read(length + TAG)
        if len(blob) != length + TAG:
            raise WZCEError("container is truncated")
        block = dec.segment(index, blob)
        digest.update(block)
        dst.write(block)
    if src.read(1):
        raise WZCEError("trailing data after final segment")
    return digest.hexdigest()


def encrypt_bytes(data: bytes, kek: bytes, object_id: bytes, segment_size: int = 4 * 1024 * 1024) -> bytes:
    out = io.BytesIO()
    encrypt_stream(io.BytesIO(data), out, kek, object_id, len(data), segment_size)
    return out.getvalue()


def decrypt_bytes(blob: bytes, kek: bytes, expected_object_id: bytes | None = None) -> bytes:
    out = io.BytesIO()
    decrypt_stream(io.BytesIO(blob), out, kek, expected_object_id)
    return out.getvalue()
