"""Token, pairing-code and device-signature helpers."""

from __future__ import annotations

import hashlib
import hmac
import secrets

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec

PAIR_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
PAIR_CODE_LENGTH = 8
REFRESH_MESSAGE_PREFIX = "WZC-REFRESH-V1"


def new_token(prefix: str) -> str:
    return prefix + secrets.token_urlsafe(32)


def new_id() -> str:
    return secrets.token_hex(16)


def hash_token(pepper: bytes, token: str) -> str:
    return hmac.new(pepper, token.encode("utf-8"), hashlib.sha256).hexdigest()


def constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8"), b.encode("utf-8"))


def new_pairing_code() -> str:
    raw = "".join(secrets.choice(PAIR_ALPHABET) for _ in range(PAIR_CODE_LENGTH))
    return f"{raw[:4]}-{raw[4:]}"


def normalize_pairing_code(code: str) -> str | None:
    cleaned = "".join(ch for ch in code.upper() if ch.isascii() and ch.isalnum())
    if len(cleaned) != PAIR_CODE_LENGTH or any(ch not in PAIR_ALPHABET for ch in cleaned):
        return None
    return cleaned


def load_device_public_key(der: bytes) -> ec.EllipticCurvePublicKey:
    """Accepts a DER SubjectPublicKeyInfo (CryptoKit `derRepresentation`) or an
    uncompressed X9.63 point (CryptoKit `x963Representation`) on P-256."""
    try:
        if len(der) == 65 and der[0] == 0x04:
            key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), der)
        else:
            key = serialization.load_der_public_key(der)
    except (ValueError, TypeError) as exc:
        raise ValueError("invalid device public key") from exc
    if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise ValueError("device key must be an EC P-256 public key")
    return key


def normalize_public_key(der: bytes) -> bytes:
    key = load_device_public_key(der)
    return key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)


def refresh_message(device_id: str, timestamp: int, refresh_token: str) -> bytes:
    token_digest = hashlib.sha256(refresh_token.encode("utf-8")).hexdigest()
    return f"{REFRESH_MESSAGE_PREFIX}\n{device_id}\n{timestamp}\n{token_digest}".encode("utf-8")


def verify_device_signature(public_key_der: bytes, message: bytes, signature_der: bytes) -> bool:
    try:
        key = load_device_public_key(public_key_der)
        key.verify(signature_der, message, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError):
        return False
