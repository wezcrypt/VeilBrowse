import base64
import json
import os
import threading
import time

import pytest
import uvicorn

import wzce
from conftest import COLLECTION, PASSWORD, encrypt_object, login, make_item, upload_object


def test_live_photo_item_roundtrip_and_restore(client, auth, keys):
    photo = encrypt_object(keys, os.urandom(400_000))
    video = encrypt_object(keys, os.urandom(900_000))
    thumb = encrypt_object(keys, os.urandom(5000))
    for obj in (photo, video, thumb):
        upload_object(client, auth, obj)
    response, body = make_item(client, auth, keys, [("photo", photo, "IMG_0001.HEIC"), ("pairedVideo", video, "IMG_0001.MOV"), ("thumbnail", thumb, "thumb.jpg")], kind="livePhoto")
    assert response.status_code == 201, response.text
    listed = client.get("/api/v2/items", headers=auth).json()["items"]
    assert len(listed) == 1 and listed[0]["kind"] == "livePhoto"
    manifest = json.loads(wzce.decrypt_bytes(base64.b64decode(listed[0]["manifest"]), keys.file_wrap, bytes.fromhex(body["item_id"])))
    assert {r["filename"] for r in manifest["resources"]} == {"IMG_0001.HEIC", "IMG_0001.MOV", "thumb.jpg"}
    assert b"IMG_0001" not in base64.b64decode(listed[0]["manifest"])


def test_duplicate_prevention(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(1000))
    upload_object(client, auth, obj)
    first, body = make_item(client, auth, keys, [("photo", obj, "a.jpg")])
    assert first.status_code == 201
    replay = client.post("/api/v2/items", json=body, headers=auth)
    assert replay.status_code == 200 and replay.json()["item_id"] == body["item_id"]
    second, _ = make_item(client, auth, keys, [("photo", obj, "a-copy.jpg")])
    assert second.status_code == 409 and second.json()["error"]["item_id"] == body["item_id"]
    check = client.post("/api/v2/items/check", json={"content_tags": [body["content_tag"], "0" * 64]}, headers=auth).json()
    assert check["existing"] == {body["content_tag"]: body["item_id"]}


def test_item_validation(client, auth, keys):
    obj = encrypt_object(keys, os.urandom(100))
    missing, _ = make_item(client, auth, keys, [("photo", obj, "x.jpg")])
    assert missing.status_code == 400 and missing.json()["error"]["code"] == "object_not_found"
    upload_object(client, auth, obj)
    _, body = make_item(client, auth, keys, [("photo", obj, "x.jpg")])
    plain = {**body, "item_id": os.urandom(16).hex(), "manifest": base64.b64encode(b'{"filename":"leak.jpg"}').decode()}
    assert client.post("/api/v2/items", json=plain, headers=auth).json()["error"]["code"] == "invalid_manifest"


def test_pagination_and_collections(client, auth, keys):
    ids = []
    for i in range(5):
        obj = encrypt_object(keys, os.urandom(200 + i))
        upload_object(client, auth, obj, collection="iphone-15" if i % 2 == 0 else "ipad")
        response, body = make_item(client, auth, keys, [("photo", obj, f"{i}.jpg")], collection="iphone-15" if i % 2 == 0 else "ipad")
        assert response.status_code == 201
        ids.append(body["item_id"])
    seen, cursor = [], None
    while True:
        params = {"limit": 2, **({"cursor": cursor} if cursor else {})}
        page = client.get("/api/v2/items", params=params, headers=auth).json()
        seen += [item["item_id"] for item in page["items"]]
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert sorted(seen) == sorted(ids) and len(seen) == 5
    assert len(client.get("/api/v2/items", params={"collection": "ipad"}, headers=auth).json()["items"]) == 2
    assert client.get("/api/v2/items", params={"cursor": "!!"}, headers=auth).status_code == 400


def test_delete_item_requires_confirmation_and_removes_objects(client, auth, keys, settings):
    obj = encrypt_object(keys, os.urandom(1000))
    upload_object(client, auth, obj)
    _, body = make_item(client, auth, keys, [("photo", obj, "a.jpg")])
    assert client.delete(f"/api/v2/objects/{obj.object_id}", headers=auth).json()["error"]["code"] == "object_in_use"
    assert client.delete(f"/api/v2/items/{body['item_id']}", headers=auth).status_code == 400
    deleted = client.delete(f"/api/v2/items/{body['item_id']}", headers={**auth, "X-WZC-Confirm-Delete": "yes"})
    assert deleted.json()["deleted_objects"] == 1
    assert list(settings.storage_root.rglob("*.wzce")) == []


def test_desktop_restore_tool_end_to_end(app, tmp_path):
    """Runs a real HTTP server and restores with only the recovery key."""
    import socket

    import wezcrypt_restore

    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    try:
        from fastapi.testclient import TestClient

        client = TestClient(app, client=("127.0.0.1", 1))
        auth = login(client)
        recovery = os.urandom(32)
        keys = wzce.VaultKeys(recovery)
        client.put("/api/v2/vault", json={"fingerprint": keys.fingerprint}, headers=auth)
        original = os.urandom(700_000)
        obj = encrypt_object(keys, original)
        upload_object(client, auth, obj)
        make_item(client, auth, keys, [("video", obj, "CLIP.MOV")], kind="video")

        remote = wezcrypt_restore.Client(f"http://127.0.0.1:{port}")
        remote.login("alice", PASSWORD)
        restored, failed = wezcrypt_restore.restore(remote, wzce.VaultKeys(wzce.parse_recovery_key(wzce.format_recovery_key(recovery))), tmp_path / "out", None)
        assert (restored, failed) == (1, 0)
        assert (tmp_path / "out" / COLLECTION / "CLIP.MOV").read_bytes() == original
        with pytest.raises(SystemExit):
            wezcrypt_restore.restore(remote, wzce.VaultKeys(os.urandom(32)), tmp_path / "bad", None)
    finally:
        server.should_exit = True
        thread.join(timeout=5)


def test_storage_events_are_audited_without_secrets(client, auth, keys, settings):
    import sqlite3

    from conftest import encrypt_object, upload_object

    obj = encrypt_object(keys, b"\x00" * 1000)
    upload_object(client, auth, obj)
    assert client.delete(f"/api/v2/objects/{obj.object_id}", headers=auth).status_code == 204
    conn = sqlite3.connect(settings.db_path)
    rows = conn.execute("SELECT event, detail FROM audit WHERE event LIKE 'object.%' ORDER BY id").fetchall()
    conn.close()
    assert rows[0] == ("object.stored", f"{obj.object_id} {len(obj.ciphertext)}")
    assert rows[1] == ("object.deleted", obj.object_id)
    for _, detail in rows:
        assert "wzt_" not in detail
