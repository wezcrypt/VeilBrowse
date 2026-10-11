import io
import os

from test_uploads import upload_all

JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 100


def seed(client, device, count=7):
    items = []
    for i in range(count):
        kind = "video" if i % 3 == 0 else "photo"
        media = upload_all(
            client,
            device,
            os.urandom(50 + i),
            filename=f"{'CLIP' if kind == 'video' else 'IMG'}_{i:04d}.{'MOV' if kind == 'video' else 'JPG'}",
            mime_type="video/quicktime" if kind == "video" else "image/jpeg",
            media_type=kind,
            taken_at=1_700_000_000 + i * 86400 * 20,
            is_screenshot=(i == 2),
            is_favorite=(i == 4),
            duration_ms=5000 if kind == "video" else None,
        )
        items.append(media)
    return items


def test_pagination_is_stable_and_complete(client, device):
    items = seed(client, device)
    seen = []
    cursor = None
    while True:
        params = {"limit": 3}
        if cursor:
            params["cursor"] = cursor
        page = client.get("/api/mobile/library", params=params, headers=device.headers).json()
        seen.extend(item["id"] for item in page["items"])
        cursor = page["next_cursor"]
        if not cursor:
            break
    expected = [m["id"] for m in sorted(items, key=lambda m: (m["taken_at"], m["id"]), reverse=True)]
    assert seen == expected


def test_filters(client, device):
    seed(client, device)
    get = lambda **p: client.get("/api/mobile/library", params=p, headers=device.headers).json()["items"]
    assert {m["media_type"] for m in get(type="video")} == {"video"}
    assert len(get(type="video")) == 3
    assert [m["filename"] for m in get(screenshot="true")] == ["IMG_0002.JPG"]
    assert [m["filename"] for m in get(favorite="true")] == ["IMG_0004.JPG"]
    assert [m["filename"] for m in get(q="0005")] == ["IMG_0005.JPG"]
    assert get(q="%") == []
    ranged = get(**{"from": 1_700_000_000 + 86400 * 20, "to": 1_700_000_000 + 86400 * 40})
    assert [m["filename"] for m in ranged] == ["IMG_0002.JPG", "IMG_0001.JPG"]
    assert client.get("/api/mobile/library", params={"cursor": "!!!"}, headers=device.headers).status_code == 400


def test_summary_buckets(client, device):
    seed(client, device)
    months = client.get("/api/mobile/library/summary", params={"granularity": "month"}, headers=device.headers).json()
    assert sum(b["count"] for b in months["buckets"]) == 7
    first = months["buckets"][0]
    assert first["start"] < first["end"]
    assert first["cover_media_id"]
    years = client.get("/api/mobile/library/summary", params={"granularity": "year"}, headers=device.headers).json()
    assert [b["key"] for b in years["buckets"]] == sorted({b["key"] for b in years["buckets"]}, reverse=True)
    days = client.get("/api/mobile/library/summary", params={"granularity": "day", "limit": 2}, headers=device.headers).json()
    assert len(days["buckets"]) == 2 and days["next_before"]
    rest = client.get(
        "/api/mobile/library/summary", params={"granularity": "day", "before": days["next_before"]}, headers=device.headers
    ).json()
    assert len(rest["buckets"]) == 5


def test_media_update_favorite_and_delete(client, app, device):
    items = seed(client, device, count=3)
    target = items[1]["id"]
    patched = client.patch(f"/api/mobile/media/{target}", json={"is_favorite": True, "filename": "Renamed.jpg"}, headers=device.headers).json()
    assert patched["is_favorite"] is True and patched["filename"] == "Renamed.jpg"

    bulk = client.post("/api/mobile/media/favorite", json={"media_ids": [i["id"] for i in items], "is_favorite": False}, headers=device.headers)
    assert bulk.json()["updated"] == 3

    unconfirmed = client.post("/api/mobile/media/delete", json={"media_ids": [target]}, headers=device.headers)
    assert unconfirmed.json()["error"]["code"] == "confirmation_required"
    deleted = client.post("/api/mobile/media/delete", json={"media_ids": [target]}, headers={**device.headers, "X-WZC-Confirm-Delete": "yes"})
    assert deleted.json()["deleted"] == 1
    assert client.get(f"/api/mobile/media/{target}", headers=device.headers).status_code == 404
    assert len(list(app.state.mobile.settings.storage_dir.rglob("*.wzc2"))) == 2


def test_thumbnails(client, device):
    media = seed(client, device, count=1)[0]
    assert client.get(f"/api/mobile/media/{media['id']}/thumbnail", headers=device.headers).status_code == 404
    assert client.put(f"/api/mobile/media/{media['id']}/thumbnail", content=b"not an image", headers=device.headers).status_code == 400
    assert client.put(f"/api/mobile/media/{media['id']}/thumbnail", content=JPEG, headers=device.headers).status_code == 204
    thumb = client.get(f"/api/mobile/media/{media['id']}/thumbnail", headers=device.headers)
    assert thumb.content == JPEG
    assert thumb.headers["content-type"] == "image/jpeg"
    assert client.get(f"/api/mobile/media/{media['id']}", headers=device.headers).json()["has_thumbnail"] is True


def test_albums_lifecycle(client, device):
    items = seed(client, device, count=4)
    ids = [m["id"] for m in items]
    album = client.post("/api/mobile/albums", json={"name": "  Trip   2024 ", "media_ids": ids[:2]}, headers=device.headers)
    assert album.status_code == 201
    album = album.json()
    assert album["name"] == "Trip 2024"
    assert album["item_count"] == 2
    assert album["total_bytes"] == items[0]["size_bytes"] + items[1]["size_bytes"]

    added = client.post(f"/api/mobile/albums/{album['id']}/items", json={"media_ids": ids[1:]}, headers=device.headers).json()
    assert added["item_count"] == 4

    removed = client.post(f"/api/mobile/albums/{album['id']}/items/remove", json={"media_ids": [ids[0]]}, headers=device.headers).json()
    assert removed["item_count"] == 3
    # Removing from an album never deletes media.
    assert client.get(f"/api/mobile/media/{ids[0]}", headers=device.headers).status_code == 200

    in_album = client.get("/api/mobile/library", params={"album_id": album["id"]}, headers=device.headers).json()["items"]
    assert {m["id"] for m in in_album} == set(ids[1:])

    renamed = client.patch(f"/api/mobile/albums/{album['id']}", json={"name": "Renamed"}, headers=device.headers).json()
    assert renamed["name"] == "Renamed"

    listing = client.get("/api/mobile/albums", headers=device.headers).json()
    assert [a["name"] for a in listing["albums"]] == ["Renamed"]
    assert listing["smart"]["videos"]["item_count"] == 2
    assert listing["smart"]["recently_added"]["item_count"] == 4

    assert client.delete(f"/api/mobile/albums/{album['id']}", headers=device.headers).status_code == 204
    assert client.get(f"/api/mobile/media/{ids[1]}", headers=device.headers).status_code == 200
    assert client.post("/api/mobile/albums", json={"name": "   "}, headers=device.headers).status_code == 400


def test_json_body_limit(client, device):
    big = {"sha256": ["0" * 64] * 2000, "pad": "x" * (2 * 1024 * 1024)}
    r = client.post("/api/mobile/sync/check", content=io.BytesIO(str(big).encode()).getvalue(), headers={**device.headers, "Content-Type": "application/json"})
    assert r.status_code == 413
