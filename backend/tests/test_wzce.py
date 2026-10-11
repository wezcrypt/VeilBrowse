import io
import os

import pytest

import wzce

KEK = bytes(range(32))


@pytest.mark.parametrize("size", [0, 1, 15, 16, 17, 1000, 70_001])
def test_roundtrip(size):
    data = os.urandom(size)
    oid = os.urandom(16)
    blob = wzce.encrypt_bytes(data, KEK, oid, segment_size=16 if size < 100 else 4096)
    assert len(blob) == wzce.ciphertext_size(size, 16 if size < 100 else 4096)
    assert wzce.decrypt_bytes(blob, KEK, oid) == data


def test_wrong_key_and_object_binding():
    oid = os.urandom(16)
    blob = wzce.encrypt_bytes(b"secret photo", KEK, oid)
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(blob, os.urandom(32), oid)
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(blob, KEK, os.urandom(16))


def test_corrupted_chunk_detected():
    oid = os.urandom(16)
    blob = bytearray(wzce.encrypt_bytes(os.urandom(10_000), KEK, oid, 1024))
    blob[wzce.HEADER_SIZE + 2000] ^= 1
    with pytest.raises(wzce.WZCEError, match="segment 1"):
        wzce.decrypt_bytes(bytes(blob), KEK, oid)


def test_reordered_segments_detected():
    oid = os.urandom(16)
    blob = wzce.encrypt_bytes(os.urandom(2048), KEK, oid, 1024)
    seg = 1024 + 16
    body = blob[wzce.HEADER_SIZE:]
    swapped = blob[: wzce.HEADER_SIZE] + body[seg:] + body[:seg]
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(swapped, KEK, oid)


def test_truncation_and_trailing_data_detected():
    oid = os.urandom(16)
    blob = wzce.encrypt_bytes(os.urandom(3000), KEK, oid, 1024)
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(blob[:-1], KEK, oid)
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(blob + b"x", KEK, oid)
    # Dropping the final segment entirely must fail too (size is authenticated).
    with pytest.raises(wzce.WZCEError):
        wzce.decrypt_bytes(blob[: wzce.HEADER_SIZE + 1040], KEK, oid)


def test_recovery_key_text_roundtrip_and_typo():
    key = os.urandom(32)
    text = wzce.format_recovery_key(key)
    assert len(text.replace("-", "")) == 55
    assert wzce.parse_recovery_key(text.lower().replace("-", " ")) == key
    broken = ("1" if text[0] != "1" else "2") + text[1:]
    with pytest.raises(wzce.WZCEError):
        wzce.parse_recovery_key(broken)


def test_key_derivation_is_deterministic_and_separated():
    key = os.urandom(32)
    a, b = wzce.VaultKeys(key), wzce.VaultKeys(key)
    assert a.fingerprint == b.fingerprint and len(a.fingerprint) == 64
    assert a.file_wrap != a.dedup
    other = wzce.VaultKeys(os.urandom(32))
    assert a.fingerprint != other.fingerprint
    tag1 = a.content_tag("photo", [("photo", "ab" * 32)])
    assert tag1 == b.content_tag("photo", [("photo", "ab" * 32)])
    assert tag1 != other.content_tag("photo", [("photo", "ab" * 32)])


def test_large_streaming_roundtrip(tmp_path):
    src = tmp_path / "video.mov"
    src.write_bytes(os.urandom(9 * 1024 * 1024 + 123))
    oid = os.urandom(16)
    enc = tmp_path / "video.wzce"
    with src.open("rb") as s, enc.open("wb") as d:
        sha_in = wzce.encrypt_stream(s, d, KEK, oid, src.stat().st_size)
    out = io.BytesIO()
    with enc.open("rb") as e:
        sha_out = wzce.decrypt_stream(e, out, KEK, oid)
    assert sha_in == sha_out
    assert out.getvalue() == src.read_bytes()


# Shared with ios/WezCryptSecureStudioTests/WZCETests.swift
VECTOR_RECOVERY_KEY = bytes(range(32))
VECTOR_OBJECT_ID = bytes(range(16, 32))
VECTOR_PLAINTEXT = b"WezCrypt Secure Studio client-side vector"


def vector_blob() -> bytes:
    keys = wzce.VaultKeys(VECTOR_RECOVERY_KEY)
    enc = wzce.Encryptor(keys.file_wrap, VECTOR_OBJECT_ID, len(VECTOR_PLAINTEXT), 16,
                         dek=bytes(range(100, 132)), nonce_prefix=bytes(range(200, 208)), key_nonce=bytes(range(12)))
    out = enc.header
    for i in range(enc.segments):
        out += enc.segment(i, VECTOR_PLAINTEXT[i * 16 : (i + 1) * 16])
    return out


def test_cross_language_vector():
    keys = wzce.VaultKeys(VECTOR_RECOVERY_KEY)
    assert keys.fingerprint == VECTOR_FINGERPRINT
    assert keys.content_tag("photo", [("photo", "00" * 32)]) == VECTOR_TAG
    assert vector_blob().hex() == VECTOR_HEX
    assert wzce.decrypt_bytes(bytes.fromhex(VECTOR_HEX), keys.file_wrap, VECTOR_OBJECT_ID) == VECTOR_PLAINTEXT


VECTOR_FINGERPRINT = "7d942a851b495aa926bdff435a205077ecc8866a5094996d51d6250132d58adc"
VECTOR_TAG = "7f28a76aafc407ac52b5a868c67d77914ec0b9133822a40ff1e1879dedf319c8"
VECTOR_HEX = (
    "575a434501010000000000100000000000000029101112131415161718191a1b1c1d1e1fc8c9cacbcccdcecf000102030405060708090a0b57c5d436dd4ee119fe73bdcb4f7c5417639fa135914ec9866da659fb7d21363c76e5eef770938d777d5c87e0dc5f12fc0da186e890ca14e6520b14d3f74ffba9c6432a38ad8bd64dd6d93a482f81cce7494f755ecdf7728626d2117dc0562a775f75fbc24781be8337fd3de780bbf9e60f318892a52fe6612d81f7e1d7eb6ab7d53c8a7f777b564bb7"
)
