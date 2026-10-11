-- WezCrypt native-app API: initial schema.
-- These tables live in a dedicated SQLite database and never touch the tables
-- used by the existing Telegram Mini App studio.

CREATE TABLE mobile_users (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    telegram_user_id INTEGER NOT NULL UNIQUE,
    created_at       INTEGER NOT NULL
);

CREATE TABLE mobile_devices (
    id             TEXT PRIMARY KEY,
    user_id        INTEGER NOT NULL REFERENCES mobile_users(id) ON DELETE CASCADE,
    name           TEXT NOT NULL,
    model          TEXT NOT NULL,
    system_version TEXT NOT NULL,
    public_key     BLOB NOT NULL,
    created_at     INTEGER NOT NULL,
    last_seen_at   INTEGER NOT NULL,
    revoked_at     INTEGER
);
CREATE INDEX ix_mobile_devices_user ON mobile_devices(user_id);

CREATE TABLE mobile_pairings (
    id               TEXT PRIMARY KEY,
    code_hash        TEXT NOT NULL UNIQUE,
    poll_secret_hash TEXT NOT NULL,
    device_name      TEXT NOT NULL,
    device_model     TEXT NOT NULL,
    system_version   TEXT NOT NULL,
    public_key       BLOB NOT NULL,
    status           TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'consumed')),
    user_id          INTEGER REFERENCES mobile_users(id) ON DELETE CASCADE,
    device_id        TEXT,
    client_ip        TEXT,
    created_at       INTEGER NOT NULL,
    expires_at       INTEGER NOT NULL
);
CREATE INDEX ix_mobile_pairings_expires ON mobile_pairings(expires_at);

CREATE TABLE mobile_tokens (
    token_hash  TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL REFERENCES mobile_devices(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL CHECK (kind IN ('access', 'refresh')),
    parent_hash TEXT,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER NOT NULL,
    used_at     INTEGER,
    revoked_at  INTEGER
);
CREATE INDEX ix_mobile_tokens_device ON mobile_tokens(device_id);
CREATE INDEX ix_mobile_tokens_parent ON mobile_tokens(parent_hash);
CREATE INDEX ix_mobile_tokens_expires ON mobile_tokens(expires_at);

CREATE TABLE mobile_media (
    id               TEXT PRIMARY KEY,
    user_id          INTEGER NOT NULL REFERENCES mobile_users(id) ON DELETE CASCADE,
    filename         TEXT NOT NULL,
    mime_type        TEXT NOT NULL,
    media_type       TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    size_bytes       INTEGER NOT NULL,
    sha256           TEXT NOT NULL,
    width            INTEGER,
    height           INTEGER,
    duration_ms      INTEGER,
    taken_at         INTEGER NOT NULL,
    added_at         INTEGER NOT NULL,
    is_favorite      INTEGER NOT NULL DEFAULT 0,
    is_screenshot    INTEGER NOT NULL DEFAULT 0,
    storage_kind     TEXT NOT NULL CHECK (storage_kind IN ('wzc2', 'legacy')),
    storage_ref      TEXT NOT NULL,
    thumb_ref        TEXT,
    local_identifier TEXT,
    source_device_id TEXT
);
CREATE UNIQUE INDEX ux_mobile_media_user_sha ON mobile_media(user_id, sha256);
CREATE INDEX ix_mobile_media_user_taken ON mobile_media(user_id, taken_at DESC, id DESC);
CREATE INDEX ix_mobile_media_user_added ON mobile_media(user_id, added_at DESC, id DESC);
CREATE INDEX ix_mobile_media_user_type ON mobile_media(user_id, media_type, taken_at DESC);
CREATE INDEX ix_mobile_media_user_fav ON mobile_media(user_id, is_favorite, taken_at DESC);

CREATE TABLE mobile_albums (
    id         TEXT PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES mobile_users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX ix_mobile_albums_user ON mobile_albums(user_id, updated_at DESC);

CREATE TABLE mobile_album_items (
    album_id TEXT NOT NULL REFERENCES mobile_albums(id) ON DELETE CASCADE,
    media_id TEXT NOT NULL REFERENCES mobile_media(id) ON DELETE CASCADE,
    added_at INTEGER NOT NULL,
    PRIMARY KEY (album_id, media_id)
);
CREATE INDEX ix_mobile_album_items_media ON mobile_album_items(media_id);

CREATE TABLE mobile_uploads (
    id           TEXT PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES mobile_users(id) ON DELETE CASCADE,
    device_id    TEXT NOT NULL REFERENCES mobile_devices(id) ON DELETE CASCADE,
    filename     TEXT NOT NULL,
    mime_type    TEXT NOT NULL,
    media_type   TEXT NOT NULL CHECK (media_type IN ('photo', 'video')),
    size_bytes   INTEGER NOT NULL,
    sha256       TEXT NOT NULL,
    upload_offset INTEGER NOT NULL DEFAULT 0,
    metadata     TEXT NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled', 'failed')),
    media_id     TEXT,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL
);
CREATE INDEX ix_mobile_uploads_device ON mobile_uploads(device_id, status);
CREATE INDEX ix_mobile_uploads_user_sha ON mobile_uploads(user_id, sha256, status);
CREATE INDEX ix_mobile_uploads_expires ON mobile_uploads(status, expires_at);

CREATE TABLE mobile_audit (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER,
    device_id  TEXT,
    event      TEXT NOT NULL,
    detail     TEXT,
    client_ip  TEXT,
    created_at INTEGER NOT NULL
);
CREATE INDEX ix_mobile_audit_user ON mobile_audit(user_id, created_at DESC);
