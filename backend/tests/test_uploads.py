import base64
import hashlib
import os

from conftest import Device, pair_device

SEG = 64 * 1024
CHUNK = 2 * SEG


def checksum(data: bytes) -> str:
    return "sha256 " + base64.b64encode(hashlib.sha256(data).digest()).decode()


def create(client, device: Device, data: bytes, **extra):
    body = {
        "filename": "IMG_0001.HEIC",
        "mime_type": "image/heic",
        "media_type": "photo",
        "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "taken_at": 1_700_000_000,
        "width": 4032,
        "height": 3024,
        **extra,
    }
    return client.post("/api/mobile/uploads", json=body, headers=device.headers)


def upload_all(client, device: Device, data: bytes, **extra) -> dict:
    session = create(client, device, data, **extra).json()
    if session["status"] == "duplicate":
        return session["media"]
    offset = session["offset"]
    while offset < len(data):
        chunk = data[offset : offset + session["chunk_size"]]
        r = client.patch(
            f"/api/mobile/uploads/{session['upload_id']}",
            content=chunk,
            headers={**device.headers, "Upload-Offset": str(offset), "Upload-Checksum": checksum(chunk)},
        )
        assert r.status_code == 200, r.text
        offset = r.json()["offset"]
    done = client.post(f"/api/mobile/uploads/{session['upload_id']}/complete", headers=device.headers)
    assert done.status_code == 200, done.text
    return done.json()["media"]


def test_chunked_upload_roundtrip_and_ranges(client, app, device):
    data = os.urandom(5 * SEG + 1234)
    media = upload_all(client, device, data)
    assert media["size_bytes"] == len(data)
    assert media["taken_at"] == 1_700_000_000

    full = client.get(f"/api/mobile/media/{media['id']}/content", headers=device.headers)
    assert full.status_code == 200
    assert full.content == data
    assert full.headers["accept-ranges"] == "bytes"

    partial = client.get(f"/api/mobile/media/{media['id']}/content", headers={**device.headers, "Range": "bytes=70000-200000"})
    assert partial.status_code == 206
    assert partial.content == data[70000:200001]
    assert partial.headers["content-range"] == f"bytes 70000-200000/{len(data)}"

    suffix = client.get(f"/api/mobile/media/{media['id']}/content", headers={**device.headers, "Range": "bytes=-100"})
    assert suffix.content == data[-100:]

    bad = client.get(f"/api/mobile/media/{media['id']}/content", headers={**device.headers, "Range": f"bytes={len(data)}-"})
    assert bad.status_code == 416

    # No plaintext remains in the upload directory and the object is encrypted at rest.
    settings = app.state.mobile.settings
    assert list(settings.upload_dir.iterdir()) == []
    stored = next(settings.storage_dir.rglob("*.wzc2")).read_bytes()
    assert stored[:4] == b"WZC2"
    assert data[:4096] not in stored


def test_duplicate_detection(client, device):
    data = os.urandom(1000)
    first = upload_all(client, device, data)
    again = create(client, device, data).json()
    assert again["status"] == "duplicate"
    assert again["media"]["id"] == first["id"]
    check = client.post("/api/mobile/sync/check", json={"sha256": [hashlib.sha256(data).hexdigest(), "0" * 64]}, headers=device.headers)
    assert check.json()["existing"] == {hashlib.sha256(data).hexdigest(): first["id"]}


def test_resume_after_interruption(client, device):
    data = os.urandom(3 * CHUNK + 10)
    session = create(client, device, data).json()
    upload_id = session["upload_id"]
    chunk = data[:CHUNK]
    client.patch(f"/api/mobile/uploads/{upload_id}", content=chunk, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(chunk)})

    # Client restarts: creating the same upload resumes the session.
    resumed = create(client, device, data).json()
    assert resumed["upload_id"] == upload_id
    assert resumed["offset"] == CHUNK
    assert client.get(f"/api/mobile/uploads/{upload_id}", headers=device.headers).json()["offset"] == CHUNK

    # Re-sending the old chunk is rejected with the current offset.
    stale = client.patch(f"/api/mobile/uploads/{upload_id}", content=chunk, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(chunk)})
    assert stale.status_code == 409
    assert stale.json()["error"]["offset"] == CHUNK

    offset = CHUNK
    while offset < len(data):
        part = data[offset : offset + CHUNK]
        r = client.patch(f"/api/mobile/uploads/{upload_id}", content=part, headers={**device.headers, "Upload-Offset": str(offset), "Upload-Checksum": checksum(part)})
        offset = r.json()["offset"]
    media = client.post(f"/api/mobile/uploads/{upload_id}/complete", headers=device.headers).json()["media"]
    assert client.get(f"/api/mobile/media/{media['id']}/content", headers=device.headers).content == data


def test_resume_from_another_device_of_same_user(client, app, device):
    data = os.urandom(CHUNK + 5)
    session = create(client, device, data).json()
    other = pair_device(client, app, name="second")
    resumed = create(client, other, data).json()
    assert resumed["upload_id"] == session["upload_id"]


def test_chunk_validation(client, device):
    data = os.urandom(CHUNK + 100)
    upload_id = create(client, device, data).json()["upload_id"]
    url = f"/api/mobile/uploads/{upload_id}"

    no_sum = client.patch(url, content=data[:SEG], headers={**device.headers, "Upload-Offset": "0"})
    assert no_sum.json()["error"]["code"] == "checksum_required"

    wrong_sum = client.patch(url, content=data[:SEG], headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(b"x")})
    assert wrong_sum.json()["error"]["code"] == "checksum_mismatch"

    misaligned = data[:1000]
    r = client.patch(url, content=misaligned, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(misaligned)})
    assert r.json()["error"]["code"] == "chunk_alignment"

    too_big = data[: CHUNK + 100]
    r = client.patch(url, content=too_big, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(too_big)})
    assert r.status_code == 413

    early = client.post(f"{url}/complete", headers=device.headers)
    assert early.json()["error"]["code"] == "upload_incomplete"


def test_hash_mismatch_fails_upload(client, device):
    data = os.urandom(500)
    session = create(client, device, data, sha256="a" * 64).json()
    r = client.patch(f"/api/mobile/uploads/{session['upload_id']}", content=data, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(data)})
    assert r.status_code == 200
    done = client.post(f"/api/mobile/uploads/{session['upload_id']}/complete", headers=device.headers)
    assert done.status_code == 422
    assert done.json()["error"]["code"] == "hash_mismatch"


def test_empty_file_upload(client, device):
    session = create(client, device, b"", filename="empty.png", mime_type="image/png").json()
    done = client.post(f"/api/mobile/uploads/{session['upload_id']}/complete", headers=device.headers)
    assert done.status_code == 200, done.text
    media = done.json()["media"]
    assert client.get(f"/api/mobile/media/{media['id']}/content", headers=device.headers).content == b""


def test_size_limit_and_mime_validation(client, device):
    huge = client.post(
        "/api/mobile/uploads",
        json={"filename": "big.mov", "mime_type": "video/quicktime", "media_type": "video", "size_bytes": 10**15, "sha256": "b" * 64},
        headers=device.headers,
    )
    assert huge.status_code == 413
    wrong = client.post(
        "/api/mobile/uploads",
        json={"filename": "a.mov", "mime_type": "image/jpeg", "media_type": "video", "size_bytes": 10, "sha256": "c" * 64},
        headers=device.headers,
    )
    assert wrong.json()["error"]["code"] == "invalid_mime_type"


def test_filename_sanitized(client, device):
    media = upload_all(client, device, os.urandom(10), filename="../../etc/\x00passwd.jpg", mime_type="image/jpeg")
    assert media["filename"] == "passwd.jpg"


def test_cancel_upload(client, app, device):
    data = os.urandom(10)
    upload_id = create(client, device, data).json()["upload_id"]
    assert client.delete(f"/api/mobile/uploads/{upload_id}", headers=device.headers).status_code == 204
    assert not app.state.mobile.store.part_path(upload_id).exists()
    assert client.patch(
        f"/api/mobile/uploads/{upload_id}", content=data, headers={**device.headers, "Upload-Offset": "0", "Upload-Checksum": checksum(data)}
    ).status_code == 410


def test_users_are_isolated(client, app, device):
    from conftest import TELEGRAM_ID

    media = upload_all(client, device, os.urandom(100))
    stranger = pair_device(client, app, telegram_id=TELEGRAM_ID + 1)
    assert client.get(f"/api/mobile/media/{media['id']}", headers=stranger.headers).status_code == 404
    assert client.get(f"/api/mobile/media/{media['id']}/content", headers=stranger.headers).status_code == 404
    assert client.get("/api/mobile/library", headers=stranger.headers).json()["items"] == []
