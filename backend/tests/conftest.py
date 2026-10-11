from __future__ import annotations

import hashlib
import os
import sys
from dataclasses import dataclass
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tools"))

from wezcrypt_backup import Settings, create_app  # noqa: E402
import wzce  # noqa: E402

PASSWORD = "correct horse battery staple"
COLLECTION = "iphone-15"


def make_settings(tmp_path: Path, **overrides) -> Settings:
    values = dict(
        storage_root=tmp_path / "iphone-backups",
        state_dir=tmp_path / "state",
        token_pepper=os.urandom(32),
        max_chunk_size=1024 * 1024,
        min_free_bytes=0,
        trust_proxy_headers=False,
    )
    values.update(overrides)
    return Settings(**values)


@pytest.fixture()
def settings(tmp_path):
    return make_settings(tmp_path)


@pytest.fixture()
def app(settings):
    application = create_app(settings)
    application.state.ctx.auth.create_user("alice", PASSWORD)
    application.state.ctx.auth.create_user("bob", PASSWORD)
    return application


@pytest.fixture()
def client(app):
    return TestClient(app, client=("127.0.0.1", 40000))


def login(client, username="alice", password=PASSWORD) -> dict:
    response = client.post("/api/v2/auth/login", json={"username": username, "password": password})
    assert response.status_code == 200, response.text
    return {"Authorization": f"Bearer {response.json()['token']}"}


@pytest.fixture()
def auth(client):
    return login(client)


@pytest.fixture()
def keys():
    return wzce.VaultKeys(os.urandom(32))


@dataclass
class UploadedObject:
    object_id: str
    ciphertext: bytes
    plaintext_sha256: str


def encrypt_object(keys, plaintext: bytes, segment_size: int = 64 * 1024) -> UploadedObject:
    object_id = os.urandom(16)
    blob = wzce.encrypt_bytes(plaintext, keys.file_wrap, object_id, segment_size)
    return UploadedObject(object_id.hex(), blob, hashlib.sha256(plaintext).hexdigest())


def start_upload(client, auth, obj: UploadedObject, chunk_size: int = 256 * 1024, collection: str = COLLECTION):
    chunk_count = (len(obj.ciphertext) + chunk_size - 1) // chunk_size
    body = {
        "object_id": obj.object_id,
        "collection": collection,
        "size_bytes": len(obj.ciphertext),
        "chunk_size": chunk_size,
        "chunk_count": chunk_count,
        "sha256": hashlib.sha256(obj.ciphertext).hexdigest(),
    }
    response = client.post("/api/v2/uploads", json=body, headers=auth)
    assert response.status_code == 200, response.text
    return response.json(), chunk_size, chunk_count


def put_chunk(client, auth, upload_id, obj, index, chunk_size, data: bytes | None = None, sha: str | None = None):
    chunk = obj.ciphertext[index * chunk_size : (index + 1) * chunk_size] if data is None else data
    headers = {**auth, "X-Chunk-SHA256": sha or hashlib.sha256(chunk).hexdigest()}
    return client.put(f"/api/v2/uploads/{upload_id}/chunks/{index}", content=chunk, headers=headers)


def upload_object(client, auth, obj: UploadedObject, chunk_size: int = 256 * 1024, collection: str = COLLECTION, order=None) -> dict:
    session, chunk_size, chunk_count = start_upload(client, auth, obj, chunk_size, collection)
    if session["status"] == "completed":
        return session
    indices = order or list(range(chunk_count))
    for index in indices:
        response = put_chunk(client, auth, session["upload_id"], obj, index, chunk_size)
        assert response.status_code == 200, response.text
    done = client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth)
    assert done.status_code == 200, done.text
    return done.json()


def make_item(client, auth, keys, objects: list[tuple[str, UploadedObject, str]], kind="photo", collection=COLLECTION):
    """objects: (role, UploadedObject, filename)."""
    import base64
    import json

    item_id = os.urandom(16)
    resources = [
        {"role": role, "object_id": obj.object_id, "filename": filename, "sha256": obj.plaintext_sha256, "size": 0}
        for role, obj, filename in objects
    ]
    manifest = wzce.encrypt_bytes(json.dumps({"v": 1, "kind": kind, "resources": resources}).encode(), keys.file_wrap, item_id)
    tag = keys.content_tag(kind, [(r["role"], r["sha256"]) for r in resources if r["role"] != "thumbnail"])
    body = {
        "item_id": item_id.hex(),
        "collection": collection,
        "content_tag": tag,
        "kind": kind,
        "manifest": base64.b64encode(manifest).decode(),
        "object_ids": [obj.object_id for _, obj, _ in objects],
    }
    return client.post("/api/v2/items", json=body, headers=auth), body
