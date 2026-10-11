from __future__ import annotations

import base64
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from wezcrypt_mobile import MobileSettings, create_mobile_app  # noqa: E402
from wezcrypt_mobile.security import refresh_message  # noqa: E402

TELEGRAM_ID = 424242


def make_settings(tmp_path: Path, **overrides) -> MobileSettings:
    values = dict(
        data_dir=tmp_path / "data",
        master_keys={1: os.urandom(32)},
        active_key_id=1,
        token_pepper=os.urandom(32),
        internal_secret="s" * 40,
        allowed_telegram_ids=frozenset({TELEGRAM_ID, TELEGRAM_ID + 1}),
        bot_username="wezcrypt_bot",
        segment_size=64 * 1024,
        chunk_segments=2,
        trust_proxy_headers=False,
    )
    values.update(overrides)
    return MobileSettings(**values)


@dataclass
class Device:
    key: ec.EllipticCurvePrivateKey
    device_id: str
    access_token: str
    refresh_token: str

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.access_token}"}

    def sign_refresh(self, timestamp: int, refresh_token: str | None = None) -> str:
        token = refresh_token or self.refresh_token
        signature = self.key.sign(refresh_message(self.device_id, timestamp, token), ec.ECDSA(hashes.SHA256()))
        return base64.b64encode(signature).decode()


@pytest.fixture()
def settings(tmp_path: Path) -> MobileSettings:
    return make_settings(tmp_path)


@pytest.fixture()
def app(settings: MobileSettings):
    return create_mobile_app(settings)


@pytest.fixture()
def client(app) -> TestClient:
    return TestClient(app, client=("127.0.0.1", 50000))


def public_key_b64(key: ec.EllipticCurvePrivateKey) -> str:
    der = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return base64.b64encode(der).decode()


def pair_device(client: TestClient, app, telegram_id: int = TELEGRAM_ID, name: str = "Test iPhone") -> Device:
    key = ec.generate_private_key(ec.SECP256R1())
    start = client.post(
        "/api/mobile/pair/start",
        json={"device_name": name, "device_model": "iPhone15,4", "system_version": "17.5", "public_key": public_key_b64(key)},
    )
    assert start.status_code == 200, start.text
    data = start.json()
    app.state.mobile.auth.approve_pairing(data["code"], telegram_id)
    poll = client.post("/api/mobile/pair/poll", json={"pairing_id": data["pairing_id"], "poll_secret": data["poll_secret"]})
    assert poll.status_code == 200, poll.text
    session = poll.json()["session"]
    return Device(key, session["device_id"], session["access_token"], session["refresh_token"])


@pytest.fixture()
def device(client, app) -> Device:
    return pair_device(client, app)
