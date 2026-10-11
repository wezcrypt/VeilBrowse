import io
import os

import pytest

from wezcrypt_mobile.crypto import (
    HEADER_SIZE,
    SegmentReader,
    WZC2Error,
    ciphertext_size,
    decrypt_bytes,
    encrypt_bytes,
    encrypt_file,
    verify_file_length,
)

KEK = bytes(range(32))


@pytest.mark.parametrize("size", [0, 1, 1023, 1024, 1025, 4096, 10_000])
def test_roundtrip(size):
    data = os.urandom(size)
    blob = encrypt_bytes(data, KEK, 1, segment_size=1024)
    assert len(blob) == ciphertext_size(size, 1024)
    assert decrypt_bytes(blob, {1: KEK}) == data


def test_header_size_is_stable():
    assert HEADER_SIZE == 89


def test_range_reads_match_plaintext():
    data = os.urandom(5000)
    blob = encrypt_bytes(data, KEK, 1, segment_size=1024)
    reader = SegmentReader(io.BytesIO(blob), {1: KEK})
    for start, end in [(0, 0), (0, 4999), (1023, 1024), (2047, 3073), (4999, 4999), (100, 2000)]:
        assert b"".join(reader.iter_range(start, end)) == data[start : end + 1]
    with pytest.raises(WZC2Error):
        list(reader.iter_range(10, 5000))


def test_tamper_detection():
    data = os.urandom(3000)
    blob = bytearray(encrypt_bytes(data, KEK, 1, segment_size=1024))
    blob[HEADER_SIZE + 5] ^= 0x01
    with pytest.raises(WZC2Error):
        decrypt_bytes(bytes(blob), {1: KEK})


def test_header_tamper_detected():
    blob = bytearray(encrypt_bytes(os.urandom(100), KEK, 1, segment_size=1024))
    blob[HEADER_SIZE - 1] ^= 0x01  # flip a bit in plaintext_size
    with pytest.raises(WZC2Error):
        decrypt_bytes(bytes(blob), {1: KEK})


def test_truncation_detected():
    blob = encrypt_bytes(os.urandom(3000), KEK, 1, segment_size=1024)
    with pytest.raises(WZC2Error):
        decrypt_bytes(blob[:-20], {1: KEK})


def test_segment_swap_detected():
    data = os.urandom(2048)
    blob = encrypt_bytes(data, KEK, 1, segment_size=1024)
    seg = 1024 + 16
    first = blob[HEADER_SIZE : HEADER_SIZE + seg]
    second = blob[HEADER_SIZE + seg : HEADER_SIZE + 2 * seg]
    swapped = blob[:HEADER_SIZE] + second + first
    with pytest.raises(WZC2Error):
        decrypt_bytes(swapped, {1: KEK})


def test_wrong_key_rejected():
    blob = encrypt_bytes(b"hello", KEK, 1)
    with pytest.raises(WZC2Error):
        decrypt_bytes(blob, {1: os.urandom(32)})
    with pytest.raises(WZC2Error):
        decrypt_bytes(blob, {2: KEK})


def test_key_rotation_keeps_old_objects_readable():
    old = encrypt_bytes(b"old object", KEK, 1)
    new_key = os.urandom(32)
    new = encrypt_bytes(b"new object", new_key, 2)
    ring = {1: KEK, 2: new_key}
    assert decrypt_bytes(old, ring) == b"old object"
    assert decrypt_bytes(new, ring) == b"new object"


def test_file_helpers(tmp_path):
    source = tmp_path / "plain.bin"
    source.write_bytes(os.urandom(70_000))
    target = tmp_path / "out.wzc2"
    encrypt_file(source, target, KEK, 1, segment_size=16 * 1024)
    header = verify_file_length(target)
    assert header.plaintext_size == 70_000
    assert (target.stat().st_mode & 0o777) == 0o600
    assert decrypt_bytes(target.read_bytes(), {1: KEK}) == source.read_bytes()


def test_cross_language_vector_is_deterministic():
    """The same vector is decrypted and re-encrypted by the iOS unit tests (WZC2InteropTests)."""
    blob = encrypt_bytes(
        b"WezCrypt Secure Studio interop vector",
        KEK,
        7,
        segment_size=16,
        dek=bytes(range(100, 132)),
        wrap_nonce=bytes(range(12)),
        nonce_prefix=bytes(range(200, 208)),
    )
    assert blob.hex() == VECTOR_HEX


VECTOR_HEX = (
    "575a4332010000001000000007000102030405060708090a0b2367b07cad8ca870e12cf9e4c1980a1ef7a3f14388022507441a9bfa9de882317e2f72945c2c0622e54e1aab08c06998c8c9cacbcccdcecf00000000000000250da186e890ca14e6520b14d3f74ffba9bab10b24dd88161e85d316d6688a59a4494f755ecdf7728c24cf1161db0b796840abeb03859240ac793ae72eb130b8db0e37dc8bb2033245a1d0d6603d6fc69dd39fdf389c"
)
