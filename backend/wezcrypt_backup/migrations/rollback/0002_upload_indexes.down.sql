-- Reverts 0002_upload_indexes.sql. Safe at any time (indexes only).
--   sqlite3 /var/lib/wezcrypt-backup/backup.sqlite3 < 0002_upload_indexes.down.sql
DROP INDEX IF EXISTS ix_uploads_user_status_updated;
DELETE FROM schema_migrations WHERE name = '0002_upload_indexes.sql';
