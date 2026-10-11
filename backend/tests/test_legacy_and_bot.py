"""Legacy (WZC1) bridge and bot helpers, exercised with an in-test fake hook module."""

import os
import sys
import types

from fastapi.testclient import TestClient

from conftest import TELEGRAM_ID, make_settings, pair_device
from wezcrypt_mobile import create_mobile_app
from wezcrypt_mobile.bot_integration import approve_in_process, parse_pair_command

LEGACY_FILES = {"legacy-1": b"\x00legacy-video-bytes" * 5000}


def _install_fake_hooks():
    module = types.ModuleType("fake_legacy_hooks")

    def open_hook(file_ref, telegram_user_id, destination):
        assert telegram_user_id == TELEGRAM_ID
        destination.write_bytes(LEGACY_FILES[file_ref])

    def list_hook(telegram_user_id):
        return [{"file_ref": "legacy-1", "filename": "old.mp4", "mime_type": "video/mp4", "size_bytes": len(LEGACY_FILES["legacy-1"]), "taken_at": 1_600_000_000}]

    def preview_hook(file_ref, telegram_user_id):
        return b"\xff\xd8\xff\xe0preview"

    module.open_hook = open_hook
    module.list_hook = list_hook
    module.preview_hook = preview_hook
    sys.modules["fake_legacy_hooks"] = module


def test_legacy_index_and_stream(tmp_path):
    _install_fake_hooks()
    settings = make_settings(
        tmp_path,
        legacy_open_hook="fake_legacy_hooks:open_hook",
        legacy_list_hook="fake_legacy_hooks:list_hook",
        legacy_preview_hook="fake_legacy_hooks:preview_hook",
    )
    app = create_mobile_app(settings)
    client = TestClient(app, client=("127.0.0.1", 1))
    device = pair_device(client, app)

    context = app.state.mobile
    imported, skipped = context.media.import_legacy(TELEGRAM_ID, context.legacy.list_files(TELEGRAM_ID))
    assert (imported, skipped) == (1, 0)
    assert context.media.import_legacy(TELEGRAM_ID, context.legacy.list_files(TELEGRAM_ID)) == (0, 1)

    items = client.get("/api/mobile/library", headers=device.headers).json()["items"]
    assert len(items) == 1 and items[0]["storage_kind"] == "legacy" and items[0]["has_thumbnail"]
    media_id = items[0]["id"]
    data = LEGACY_FILES["legacy-1"]
    r = client.get(f"/api/mobile/media/{media_id}/content", headers={**device.headers, "Range": "bytes=10-99"})
    assert r.status_code == 206 and r.content == data[10:100]
    cached = list(settings.legacy_cache_dir.glob("*.plain"))
    assert len(cached) == 1 and (cached[0].stat().st_mode & 0o777) == 0o600

    thumb = client.get(f"/api/mobile/media/{media_id}/thumbnail", headers=device.headers)
    assert thumb.content.startswith(b"\xff\xd8\xff")

    # Deleting a legacy entry removes only the index row, never the WZC1 object.
    client.post("/api/mobile/media/delete", json={"media_ids": [media_id]}, headers={**device.headers, "X-WZC-Confirm-Delete": "yes"})
    assert "legacy-1" in LEGACY_FILES


def test_legacy_storage_mode_uses_store_hook(tmp_path):
    stored = {}
    module = types.ModuleType("fake_store_hooks")

    def store_hook(plaintext_path, telegram_user_id, filename, mime_type):
        stored["data"] = plaintext_path.read_bytes()
        stored["mode"] = plaintext_path.stat().st_mode & 0o777
        return "wzc1-ref-1"

    module.store_hook = store_hook
    sys.modules["fake_store_hooks"] = module
    settings = make_settings(tmp_path, storage_format="legacy", legacy_store_hook="fake_store_hooks:store_hook")
    app = create_mobile_app(settings)
    client = TestClient(app, client=("127.0.0.1", 1))
    device = pair_device(client, app)

    from test_uploads import upload_all

    data = os.urandom(3000)
    media = upload_all(client, device, data)
    assert media["storage_kind"] == "legacy"
    assert stored["data"] == data
    assert stored["mode"] == 0o600
    assert list(settings.upload_dir.iterdir()) == []


def test_parse_pair_command():
    assert parse_pair_command("/pair ABCD-EFGH") == "ABCD-EFGH"
    assert parse_pair_command("/pair@wezcrypt_bot abcd-efgh") == "abcd-efgh"
    assert parse_pair_command("/start pair_ABCDEFGH") == "ABCDEFGH"
    assert parse_pair_command("/start") is None
    assert parse_pair_command("hello") is None
    assert parse_pair_command(None) is None


def test_approve_in_process_messages(client, app):
    from cryptography.hazmat.primitives.asymmetric import ec

    from conftest import public_key_b64

    result = approve_in_process(app.state.mobile, "ZZZZ-ZZZZ", TELEGRAM_ID)
    assert not result.ok and "expired" in result.message
    key = ec.generate_private_key(ec.SECP256R1())
    start = client.post(
        "/api/mobile/pair/start",
        json={"device_name": "Phone", "device_model": "iPhone16,1", "system_version": "18.0", "public_key": public_key_b64(key)},
    ).json()
    ok = approve_in_process(app.state.mobile, start["code"], TELEGRAM_ID)
    assert ok.ok and ok.device_name == "Phone"
