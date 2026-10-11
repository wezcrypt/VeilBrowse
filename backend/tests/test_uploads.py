import hashlib
import os

import wzce
from conftest import COLLECTION, encrypt_object, login, put_chunk, start_upload, upload_object


def test_large_object_roundtrip_out_of_order(client, auth, keys, settings):
    plaintext = os.urandom(3 * 1024 * 1024 + 4321)
    obj = encrypt_object(keys, plaintext, segment_size=256 * 1024)
    session, chunk_size, chunk_count = start_upload(client, auth, obj, chunk_size=512 * 1024)
    order = list(range(chunk_count))[::-1]
    for index in order:
        assert put_chunk(client, auth, session["upload_id"], obj, index, chunk_size).status_code == 200
    done = client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth).json()
    assert done["status"] == "completed"

    full = client.get(f"/api/v2/objects/{obj.object_id}", headers=auth)
    assert full.status_code == 200
    assert full.headers["x-content-sha256"] == hashlib.sha256(obj.ciphertext).hexdigest()
    assert wzce.decrypt_bytes(full.content, keys.file_wrap, bytes.fromhex(obj.object_id)) == plaintext

    part = client.get(f"/api/v2/objects/{obj.object_id}", headers={**auth, "Range": "bytes=100-1099"})
    assert part.status_code == 206 and part.content == obj.ciphertext[100:1100]
    head = client.head(f"/api/v2/objects/{obj.object_id}", headers=auth)
    assert head.status_code == 200 and int(head.headers["content-length"]) == len(obj.ciphertext)

    stored = next(settings.storage_root.rglob("*.wzce"))
    assert stored.relative_to(settings.storage_root).parts[:3] == ("alice", COLLECTION, "objects")
    assert plaintext[:4096] not in stored.read_bytes()
    assert list((settings.storage_root / ".uploads").iterdir()) == []


def test_interrupted_upload_resumes(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(1_500_000))
    session, chunk_size, chunk_count = start_upload(client, auth, obj)
    for index in (0, 2):
        put_chunk(client, auth, session["upload_id"], obj, index, chunk_size)
    # The app restarts: creating the same object returns the same session and the received chunks.
    resumed, _, _ = start_upload(client, auth, obj)
    assert resumed["upload_id"] == session["upload_id"]
    assert [c["index"] for c in resumed["received"]] == [0, 2]
    early = client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth)
    assert early.status_code == 409 and early.json()["error"]["missing"] == [i for i in range(chunk_count) if i not in (0, 2)]
    for index in range(chunk_count):
        if index not in (0, 2):
            put_chunk(client, auth, session["upload_id"], obj, index, chunk_size)
    assert client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth).status_code == 200
    # Uploading the same object again is a no-op.
    again, _, _ = start_upload(client, auth, obj)
    assert again["status"] == "completed"


def test_chunk_retry_is_idempotent_and_conflicts_detected(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(600_000))
    session, chunk_size, _ = start_upload(client, auth, obj)
    first = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size)
    retry = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size)
    assert first.json()["status"] == "received" and retry.json()["status"] == "already_received"
    other = os.urandom(chunk_size)
    conflict = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size, data=other)
    assert conflict.status_code == 409 and conflict.json()["error"]["code"] == "chunk_conflict"


def test_corrupted_chunk_rejected(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(600_000))
    session, chunk_size, _ = start_upload(client, auth, obj)
    good = obj.ciphertext[:chunk_size]
    corrupted = bytearray(good)
    corrupted[10] ^= 1
    bad = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size, data=bytes(corrupted), sha=hashlib.sha256(good).hexdigest())
    assert bad.status_code == 400 and bad.json()["error"]["code"] == "checksum_mismatch"
    no_hash = client.put(f"/api/v2/uploads/{session['upload_id']}/chunks/0", content=good, headers=auth)
    assert no_hash.json()["error"]["code"] == "checksum_required"
    wrong_size = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size, data=good[:-1])
    assert wrong_size.status_code == 400
    out_of_range = put_chunk(client, auth, session["upload_id"], obj, 99, chunk_size, data=good)
    assert out_of_range.json()["error"]["code"] == "invalid_chunk_index"


def test_object_hash_mismatch_at_completion(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(300_000))
    chunk_size = 256 * 1024
    body = {"object_id": obj.object_id, "collection": COLLECTION, "size_bytes": len(obj.ciphertext), "chunk_size": chunk_size,
            "chunk_count": 2, "sha256": "0" * 64}
    session = client.post("/api/v2/uploads", json=body, headers=auth).json()
    for index in range(2):
        put_chunk(client, auth, session["upload_id"], obj, index, chunk_size)
    done = client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth)
    assert done.status_code == 422 and done.json()["error"]["code"] == "object_hash_mismatch"
    assert client.get(f"/api/v2/objects/{obj.object_id}", headers=auth).status_code == 404


def test_upload_validation(client, auth):
    base = {"object_id": "a" * 32, "collection": COLLECTION, "size_bytes": 10, "chunk_size": 4, "chunk_count": 3, "sha256": "b" * 64}
    assert client.post("/api/v2/uploads", json=base, headers=auth).status_code == 200
    assert client.post("/api/v2/uploads", json={**base, "object_id": "c" * 32, "chunk_count": 2}, headers=auth).json()["error"]["code"] == "invalid_chunk_count"
    assert client.post("/api/v2/uploads", json={**base, "object_id": "../" + "a" * 29}, headers=auth).json()["error"]["code"] == "invalid_id"
    assert client.post("/api/v2/uploads", json={**base, "object_id": "d" * 32, "collection": "../etc"}, headers=auth).json()["error"]["code"] == "invalid_collection"
    assert client.post("/api/v2/uploads", json={**base, "object_id": "e" * 32, "chunk_size": 64 * 1024 * 1024, "chunk_count": 1}, headers=auth).json()["error"]["code"] == "invalid_chunk_size"
    assert client.post("/api/v2/uploads", json={**base, "object_id": "f" * 32, "size_bytes": 0, "chunk_count": 0}, headers=auth).status_code == 413
    assert client.post("/api/v2/uploads", json={**base, "chunk_size": 5, "chunk_count": 2}, headers=auth).json()["error"]["code"] == "upload_mismatch"


def test_cancel_upload(client, auth, keys, settings):
    obj = encrypt_object(keys, os.urandom(1000))
    session, chunk_size, _ = start_upload(client, auth, obj)
    put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size)
    assert client.delete(f"/api/v2/uploads/{session['upload_id']}", headers=auth).status_code == 204
    assert not (settings.upload_dir / session["upload_id"]).exists()
    assert put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size).status_code == 410


def test_quota_and_low_disk(client, app, auth, keys, tmp_path):
    app.state.ctx.auth.set_quota("alice", 1000)
    obj = encrypt_object(keys, os.urandom(5000))
    body = {"object_id": obj.object_id, "collection": COLLECTION, "size_bytes": len(obj.ciphertext), "chunk_size": 1 << 20,
            "chunk_count": 1, "sha256": hashlib.sha256(obj.ciphertext).hexdigest()}
    quota = client.post("/api/v2/uploads", json=body, headers=auth)
    assert quota.status_code == 507 and quota.json()["error"]["code"] == "quota_exceeded"
    app.state.ctx.auth.set_quota("alice", None)
    app.state.ctx.service.settings = app.state.ctx.service.settings.__class__(
        **{**app.state.ctx.service.settings.__dict__, "min_free_bytes": 10**18})
    low = client.post("/api/v2/uploads", json=body, headers=auth)
    assert low.status_code == 507 and low.json()["error"]["code"] == "insufficient_storage"


def test_users_are_isolated(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(2000))
    upload_object(client, auth, obj)
    bob = login(client, "bob")
    assert client.get(f"/api/v2/objects/{obj.object_id}", headers=bob).status_code == 404
    assert client.delete(f"/api/v2/objects/{obj.object_id}", headers=bob).status_code == 404
    # Same object id under another user is a separate namespace.
    session, _, _ = start_upload(client, bob, obj)
    assert session["status"] == "active"


def test_delete_unreferenced_object(client, auth, keys, settings):
    obj = encrypt_object(keys, os.urandom(2000))
    upload_object(client, auth, obj)
    assert client.delete(f"/api/v2/objects/{obj.object_id}", headers=auth).status_code == 204
    assert list(settings.storage_root.rglob("*.wzce")) == []


def test_purge_expired_uploads(client, app, auth, keys, settings):
    import time

    obj = encrypt_object(keys, os.urandom(1000))
    session, chunk_size, _ = start_upload(client, auth, obj)
    put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size)
    app.state.ctx.service.clock = lambda: time.time() + 8 * 86400
    assert app.state.ctx.service.purge() == 1
    assert not (settings.upload_dir / session["upload_id"]).exists()
