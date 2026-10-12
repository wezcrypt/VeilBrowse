"""Upload back-pressure: session limits, abandoned-session reclaim, per-user chunk
concurrency, Retry-After, expiry refresh and stats."""

import hashlib
import os
import time

import pytest

from conftest import COLLECTION, encrypt_object, login, make_settings, put_chunk, start_upload, upload_object
from wezcrypt_backup import create_app
from wezcrypt_backup.ratelimit import ConcurrencyLimiter


def _session_body(obj, chunk_size=256 * 1024):
    return {
        "object_id": obj.object_id,
        "collection": COLLECTION,
        "size_bytes": len(obj.ciphertext),
        "chunk_size": chunk_size,
        "chunk_count": (len(obj.ciphertext) + chunk_size - 1) // chunk_size,
        "sha256": hashlib.sha256(obj.ciphertext).hexdigest(),
    }


@pytest.fixture()
def small_limits(tmp_path):
    from conftest import PASSWORD
    from fastapi.testclient import TestClient

    settings = make_settings(tmp_path, max_active_uploads_per_user=4, max_inflight_chunks_per_user=2, abandoned_upload_seconds=60)
    app = create_app(settings)
    app.state.ctx.auth.create_user("alice", PASSWORD)
    client = TestClient(app, client=("127.0.0.1", 40001))
    return app, client, login(client)


def test_session_limit_returns_retry_after(small_limits, keys):
    app, client, auth = small_limits
    for _ in range(4):
        assert client.post("/api/v2/uploads", json=_session_body(encrypt_object(keys, os.urandom(500))), headers=auth).status_code == 200
    busy = client.post("/api/v2/uploads", json=_session_body(encrypt_object(keys, os.urandom(500))), headers=auth)
    assert busy.status_code == 429
    assert busy.json()["error"]["code"] == "too_many_uploads"
    assert int(busy.headers["Retry-After"]) >= 1
    assert busy.json()["error"]["retry_after"] >= 1


def test_same_object_session_is_idempotent_and_does_not_count_twice(small_limits, keys):
    app, client, auth = small_limits
    obj = encrypt_object(keys, os.urandom(500))
    first = client.post("/api/v2/uploads", json=_session_body(obj), headers=auth).json()
    for _ in range(10):
        again = client.post("/api/v2/uploads", json=_session_body(obj), headers=auth)
        assert again.status_code == 200
        assert again.json()["upload_id"] == first["upload_id"]
    assert client.get("/api/v2/stats", headers=auth).json()["user"]["open_upload_sessions"] == 1


def test_abandoned_sessions_are_reclaimed_but_live_ones_are_kept(small_limits, keys):
    app, client, auth = small_limits
    service = app.state.ctx.service
    live = encrypt_object(keys, os.urandom(300 * 1024))
    live_session, chunk_size, _ = start_upload(client, auth, live)
    assert put_chunk(client, auth, live_session["upload_id"], live, 0, chunk_size).status_code == 200
    for _ in range(3):
        client.post("/api/v2/uploads", json=_session_body(encrypt_object(keys, os.urandom(500))), headers=auth)
    # Ten minutes later: the three empty sessions are abandoned, the live one has data.
    service.clock = lambda: time.time() + 600
    fresh = client.post("/api/v2/uploads", json=_session_body(encrypt_object(keys, os.urandom(500))), headers=auth)
    assert fresh.status_code == 200, fresh.text
    stats = client.get("/api/v2/stats", headers=auth).json()
    assert stats["user"]["open_upload_sessions"] == 2
    assert stats["server"]["sessions_reclaimed"] == 3
    # The live upload continues where it stopped.
    status = client.get(f"/api/v2/uploads/{live_session['upload_id']}", headers=auth).json()
    assert status["status"] == "active" and [c["index"] for c in status["received"]] == [0]
    assert put_chunk(client, auth, live_session["upload_id"], live, 1, chunk_size).status_code == 200
    assert client.post(f"/api/v2/uploads/{live_session['upload_id']}/complete", headers=auth).status_code == 200


def test_chunk_activity_extends_expiry_so_purge_never_hits_live_uploads(client, app, auth, keys, settings):
    service = app.state.ctx.service
    obj = encrypt_object(keys, os.urandom(600 * 1024))
    session, chunk_size, chunk_count = start_upload(client, auth, obj)
    base = time.time()
    service.clock = lambda: base + 6 * 86400  # one day before the original expiry
    assert put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size).status_code == 200
    service.clock = lambda: base + 8 * 86400  # past the original expiry, within the refreshed one
    assert service.purge() == 0
    for index in range(1, chunk_count):
        assert put_chunk(client, auth, session["upload_id"], obj, index, chunk_size).status_code == 200
    assert client.post(f"/api/v2/uploads/{session['upload_id']}/complete", headers=auth).status_code == 200


def test_chunk_concurrency_limit_and_slots_are_released(small_limits, keys):
    app, client, auth = small_limits
    service = app.state.ctx.service
    obj = encrypt_object(keys, os.urandom(300 * 1024))
    session, chunk_size, _ = start_upload(client, auth, obj)
    user_id = 1  # first user created in this database (alice)
    # Occupy both slots as if two requests were streaming.
    assert service.chunk_slots.acquire(str(user_id)) and service.chunk_slots.acquire(str(user_id))
    busy = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size)
    assert busy.status_code == 429
    assert busy.json()["error"]["code"] == "too_many_chunk_requests"
    assert busy.headers["Retry-After"] == "2"
    service.chunk_slots.release(str(user_id))
    service.chunk_slots.release(str(user_id))
    # Failing requests (bad checksum, wrong size) must not leak slots.
    for _ in range(5):
        bad = put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size, sha="0" * 64)
        assert bad.status_code == 400
    assert service.chunk_slots.active(str(user_id)) == 0
    assert put_chunk(client, auth, session["upload_id"], obj, 0, chunk_size).status_code == 200
    assert service.chunk_slots.active(str(user_id)) == 0


def test_concurrency_limiter_unit():
    limiter = ConcurrencyLimiter(2)
    assert limiter.acquire("a") and limiter.acquire("a")
    assert not limiter.acquire("a")
    assert limiter.acquire("b")
    limiter.release("a")
    assert limiter.acquire("a")
    for _ in range(5):
        limiter.release("a")
    assert limiter.active("a") == 0
    assert limiter.total() == 1


def test_stats_contain_no_identifiers(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(2000))
    upload_object(client, auth, obj)
    body = client.get("/api/v2/stats", headers=auth)
    assert body.status_code == 200
    assert obj.object_id not in body.text
    data = body.json()
    assert data["user"]["stored_objects"] == 1
    assert data["server"]["objects_completed"] >= 1
    assert data["limits"]["max_concurrent_chunk_requests"] >= 1
    assert client.get("/api/v2/stats").status_code == 401


def test_thousand_small_objects_never_exceed_limits(small_limits, keys):
    """1,000 files uploaded the way the iOS client now does it: a session is opened
    only for the object being sent, so open sessions never approach the limit."""
    app, client, auth = small_limits
    peak = 0
    for _ in range(1000):
        obj = encrypt_object(keys, os.urandom(64))
        upload_object(client, auth, obj)
        peak = max(peak, client.get("/api/v2/stats", headers=auth).json()["user"]["open_upload_sessions"]) if _ % 100 == 0 else peak
    stats = client.get("/api/v2/stats", headers=auth).json()
    assert stats["user"]["stored_objects"] == 1000
    assert stats["user"]["open_upload_sessions"] == 0
    assert stats["server"]["sessions_rejected_busy"] == 0
    assert peak <= 1
