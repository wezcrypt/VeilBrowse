-- Indexes for upload session accounting (count of open sessions per user,
-- abandoned-session reclaim, purge of expired sessions). Additive only: no data
-- is changed. Rollback: migrations/rollback/0002_upload_indexes.down.sql
CREATE INDEX IF NOT EXISTS ix_uploads_user_status_updated ON uploads(user_id, status, updated_at);
