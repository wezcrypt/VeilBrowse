import time

from conftest import PASSWORD, login


def test_login_and_me(client, auth):
    me = client.get("/api/v2/me", headers=auth)
    assert me.status_code == 200
    body = me.json()
    assert body["username"] == "alice"
    assert body["credential"] == "session"
    assert body["disk_free_bytes"] > 0
    assert body["vault_configured"] is False


def test_incorrect_password_and_unknown_user(client):
    wrong = client.post("/api/v2/auth/login", json={"username": "alice", "password": "nope-nope-nope"})
    assert wrong.status_code == 401
    assert wrong.json()["error"]["code"] == "invalid_credentials"
    unknown = client.post("/api/v2/auth/login", json={"username": "mallory", "password": PASSWORD})
    assert unknown.status_code == 401
    assert unknown.json()["error"]["code"] == "invalid_credentials"


def test_login_rate_limit(client):
    codes = [client.post("/api/v2/auth/login", json={"username": "bob", "password": "wrong-password!"}).status_code for _ in range(9)]
    assert codes[:8] == [401] * 8
    assert codes[8] == 429


def test_unauthorized_access(client):
    assert client.get("/api/v2/me").status_code == 401
    assert client.get("/api/v2/me", headers={"Authorization": "Bearer wzt_forged"}).status_code == 401
    assert client.get("/api/v2/items", headers={"Authorization": "Basic abc"}).status_code == 401
    assert client.post("/api/v2/uploads", json={}).status_code in (401, 422)


def test_logout_revokes_session(client, auth):
    assert client.post("/api/v2/auth/logout", headers=auth).status_code == 204
    assert client.get("/api/v2/me", headers=auth).status_code == 401


def test_password_change_revokes_sessions(client, app, auth):
    app.state.ctx.auth.set_password("alice", "another long password!")
    assert client.get("/api/v2/me", headers=auth).status_code == 401
    login(client, "alice", "another long password!")


def test_api_key_auth_and_revocation(client, app):
    key = app.state.ctx.auth.create_api_key("alice", "iphone")
    headers = {"Authorization": f"Bearer {key}"}
    me = client.get("/api/v2/me", headers=headers).json()
    assert me["credential"] == "api_key"
    assert client.post("/api/v2/auth/logout", headers=headers).status_code == 400
    app.state.ctx.auth.revoke_api_keys("alice")
    assert client.get("/api/v2/me", headers=headers).status_code == 401


def test_disabled_user(client, app, auth):
    app.state.ctx.auth.set_disabled("alice", True)
    assert client.get("/api/v2/me", headers=auth).status_code == 401
    assert client.post("/api/v2/auth/login", json={"username": "alice", "password": PASSWORD}).status_code == 401


def test_session_expiry(client, app, auth):
    app.state.ctx.auth.clock = lambda: time.time() + 31 * 86400
    response = client.get("/api/v2/me", headers=auth)
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


def test_weak_password_rejected(app):
    import pytest

    with pytest.raises(ValueError):
        app.state.ctx.auth.create_user("carol", "short")
    with pytest.raises(ValueError):
        app.state.ctx.auth.create_user("../etc", "long enough password")


def test_vault_fingerprint_is_write_once(client, auth, keys):
    assert client.get("/api/v2/vault", headers=auth).status_code == 404
    ok = client.put("/api/v2/vault", json={"fingerprint": keys.fingerprint}, headers=auth)
    assert ok.status_code == 200
    assert client.put("/api/v2/vault", json={"fingerprint": keys.fingerprint}, headers=auth).status_code == 200
    other = client.put("/api/v2/vault", json={"fingerprint": "a" * 64}, headers=auth)
    assert other.status_code == 409
    assert other.json()["error"]["code"] == "vault_mismatch"
    assert client.get("/api/v2/vault", headers=auth).json()["fingerprint"] == keys.fingerprint
