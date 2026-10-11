-- WezCrypt encrypted backup service. Stores only ciphertext and encrypted manifests.

CREATE TABLE users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT NOT NULL UNIQUE,
    password_hash TEXT,
    quota_bytes   INTEGER,
    disabled      INTEGER NOT NULL DEFAULT 0,
    created_at    INTEGER NOT NULL
);

CREATE TABLE tokens (
    token_hash  TEXT PRIMARY KEY,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        TEXT NOT NULL CHECK (kind IN ('session', 'api_key')),
    label       TEXT,
    created_at  INTEGER NOT NULL,
    expires_at  INTEGER,
    last_used_at INTEGER,
    revoked_at  INTEGER
);
CREATE INDEX ix_tokens_user ON tokens(user_id, kind);

CREATE TABLE vaults (
    user_id     INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    fingerprint TEXT NOT NULL,
    format      TEXT NOT NULL,
    created_at  INTEGER NOT NULL
);

CREATE TABLE uploads (
    id           TEXT PRIMARY KEY,
    user_id      INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    object_id    TEXT NOT NULL,
    collection   TEXT NOT NULL,
    size_bytes   INTEGER NOT NULL,
    chunk_size   INTEGER NOT NULL,
    chunk_count  INTEGER NOT NULL,
    sha256       TEXT NOT NULL,
    status       TEXT NOT NULL CHECK (status IN ('active', 'completed', 'cancelled')),
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    expires_at   INTEGER NOT NULL
);
CREATE UNIQUE INDEX ux_uploads_active_object ON uploads(user_id, object_id) WHERE status = 'active';
CREATE INDEX ix_uploads_expiry ON uploads(status, expires_at);

CREATE TABLE upload_chunks (
    upload_id  TEXT NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
    idx        INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL,
    sha256     TEXT NOT NULL,
    received_at INTEGER NOT NULL,
    PRIMARY KEY (upload_id, idx)
);

CREATE TABLE objects (
    id          TEXT NOT NULL,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    collection  TEXT NOT NULL,
    size_bytes  INTEGER NOT NULL,
    sha256      TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
);

CREATE TABLE items (
    id            TEXT NOT NULL,
    user_id       INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    collection    TEXT NOT NULL,
    content_tag   TEXT NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('photo', 'video', 'livePhoto', 'file')),
    manifest      BLOB NOT NULL,
    total_bytes   INTEGER NOT NULL,
    created_at    INTEGER NOT NULL,
    PRIMARY KEY (user_id, id)
);
CREATE UNIQUE INDEX ux_items_tag ON items(user_id, content_tag);
CREATE INDEX ix_items_list ON items(user_id, collection, created_at DESC, id DESC);

CREATE TABLE item_objects (
    user_id   INTEGER NOT NULL,
    item_id   TEXT NOT NULL,
    object_id TEXT NOT NULL,
    PRIMARY KEY (user_id, item_id, object_id)
);
CREATE INDEX ix_item_objects_object ON item_objects(user_id, object_id);

CREATE TABLE audit (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER,
    event      TEXT NOT NULL,
    detail     TEXT,
    client_ip  TEXT,
    created_at INTEGER NOT NULL
);
