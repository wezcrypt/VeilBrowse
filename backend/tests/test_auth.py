import time

from cryptography.hazmat.primitives.asymmetric import ec

from conftest import TELEGRAM_ID, Device, pair_device, public_key_b64


def test_pairing_flow_and_single_use_tokens(client, app):
    key = ec.generate_private_key(ec.SECP256R1())
    start = client.post(
        "/api/mobile/pair/start",
        json={"device_name": "My iPhone", "device_model": "iPhone15,4", "system_version": "17.5", "public_key": public_key_b64(key)},
    ).json()
    assert len(start["code"]) == 9 and start["code"][4] == "-"
    assert start["telegram_link"] == f"https://t.me/wezcrypt_bot?start=pair_{start['code'].replace('-', '')}"

    body = {"pairing_id": start["pairing_id"], "poll_secret": start["poll_secret"]}
    assert client.post("/api/mobile/pair/poll", json=body).json() == {"status": "pending"}

    wrong = dict(body, poll_secret="wzp_wrongwrongwrong")
    assert client.post("/api/mobile/pair/poll", json=wrong).status_code == 404

    app.state.mobile.auth.approve_pairing(start["code"].lower().replace("-", " "), TELEGRAM_ID)
    approved = client.post("/api/mobile/pair/poll", json=body).json()
    assert approved["status"] == "approved"
    assert approved["session"]["access_token"].startswith("wza_")
    assert client.post("/api/mobile/pair/poll", json=body).json() == {"status": "consumed"}

    headers = {"Authorization": f"Bearer {approved['session']['access_token']}"}
    account = client.get("/api/mobile/account", headers=headers)
    assert account.status_code == 200
    assert account.json()["encryption"]["end_to_end"] is False


def test_disallowed_telegram_user_cannot_pair(client, app):
    key = ec.generate_private_key(ec.SECP256R1())
    start = client.post(
        "/api/mobile/pair/start",
        json={"device_name": "x", "device_model": "y", "system_version": "17", "public_key": public_key_b64(key)},
    ).json()
    import pytest

    from wezcrypt_mobile.errors import APIError

    with pytest.raises(APIError) as exc:
        app.state.mobile.auth.approve_pairing(start["code"], 999)
    assert exc.value.code == "not_allowed"


def test_invalid_public_key_rejected(client):
    response = client.post(
        "/api/mobile/pair/start",
        json={"device_name": "x", "device_model": "y", "system_version": "17", "public_key": "A" * 60},
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_public_key"


def test_unauthenticated_requests_rejected(client):
    assert client.get("/api/mobile/library").status_code == 401
    assert client.get("/api/mobile/library", headers={"Authorization": "Bearer wza_nope"}).status_code == 401


def test_refresh_requires_device_signature(client, device: Device):
    now = int(time.time())
    other_key = ec.generate_private_key(ec.SECP256R1())
    forged = Device(other_key, device.device_id, device.access_token, device.refresh_token)
    bad = client.post(
        "/api/mobile/session/refresh",
        json={"device_id": device.device_id, "refresh_token": device.refresh_token, "timestamp": now, "signature": forged.sign_refresh(now)},
    )
    assert bad.status_code == 401
    assert bad.json()["error"]["code"] == "invalid_signature"

    stale = client.post(
        "/api/mobile/session/refresh",
        json={"device_id": device.device_id, "refresh_token": device.refresh_token, "timestamp": now - 3600, "signature": device.sign_refresh(now - 3600)},
    )
    assert stale.json()["error"]["code"] == "clock_skew"

    good = client.post(
        "/api/mobile/session/refresh",
        json={"device_id": device.device_id, "refresh_token": device.refresh_token, "timestamp": now, "signature": device.sign_refresh(now)},
    )
    assert good.status_code == 200, good.text
    new = good.json()
    assert new["refresh_token"] != device.refresh_token
    assert client.get("/api/mobile/account", headers={"Authorization": f"Bearer {new['access_token']}"}).status_code == 200


def test_refresh_retry_within_grace_then_reuse_detection(client, app, device: Device):
    auth = app.state.mobile.auth
    now = int(time.time())
    payload = {"device_id": device.device_id, "refresh_token": device.refresh_token, "timestamp": now, "signature": device.sign_refresh(now)}
    first = client.post("/api/mobile/session/refresh", json=payload).json()
    retry = client.post("/api/mobile/session/refresh", json=payload)
    assert retry.status_code == 200
    # The first rotation is replaced by the retry.
    assert client.get("/api/mobile/account", headers={"Authorization": f"Bearer {first['access_token']}"}).status_code == 401

    auth.clock = lambda: now + 120
    later = now + 120
    payload_late = dict(payload, timestamp=later, signature=device.sign_refresh(later))
    reuse = client.post("/api/mobile/session/refresh", json=payload_late)
    assert reuse.status_code == 401
    assert reuse.json()["error"]["code"] == "refresh_reuse"
    assert client.get("/api/mobile/account", headers={"Authorization": f"Bearer {retry.json()['access_token']}"}).status_code == 401


def test_access_token_expiry(client, app, device: Device):
    auth = app.state.mobile.auth
    auth.clock = lambda: time.time() + 16 * 60
    response = client.get("/api/mobile/account", headers=device.headers)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


def test_device_listing_and_revocation(client, app, device: Device):
    second = pair_device(client, app, name="iPad")
    devices = client.get("/api/mobile/devices", headers=device.headers).json()["devices"]
    assert {d["name"] for d in devices} == {"Test iPhone", "iPad"}
    assert [d for d in devices if d["is_current"]][0]["id"] == device.device_id

    assert client.delete(f"/api/mobile/devices/{second.device_id}", headers=device.headers).status_code == 204
    assert client.get("/api/mobile/account", headers=second.headers).status_code == 401

    other_user = pair_device(client, app, telegram_id=TELEGRAM_ID + 1)
    assert client.delete(f"/api/mobile/devices/{device.device_id}", headers=other_user.headers).status_code == 404


def test_logout_revokes_current_device(client, device: Device):
    assert client.post("/api/mobile/session/logout", headers=device.headers).status_code == 204
    assert client.get("/api/mobile/account", headers=device.headers).status_code == 401


def test_internal_approve_endpoint_protection(client, app):
    key = ec.generate_private_key(ec.SECP256R1())
    start = client.post(
        "/api/mobile/pair/start",
        json={"device_name": "x", "device_model": "y", "system_version": "17", "public_key": public_key_b64(key)},
    ).json()
    body = {"code": start["code"], "telegram_user_id": TELEGRAM_ID}
    assert client.post("/api/mobile/internal/pair/approve", json=body).status_code == 403
    assert client.post(
        "/api/mobile/internal/pair/approve", json=body, headers={"X-WZC-Internal-Secret": "s" * 40, "X-Forwarded-For": "1.2.3.4"}
    ).status_code == 403
    ok = client.post("/api/mobile/internal/pair/approve", json=body, headers={"X-WZC-Internal-Secret": "s" * 40})
    assert ok.status_code == 200
    assert ok.json()["device_name"] == "x"


def test_pair_start_rate_limited(client):
    key = ec.generate_private_key(ec.SECP256R1())
    body = {"device_name": "x", "device_model": "y", "system_version": "17", "public_key": public_key_b64(key)}
    codes = [client.post("/api/mobile/pair/start", json=body).status_code for _ in range(12)]
    assert codes[:10] == [200] * 10
    assert codes[-1] == 429
