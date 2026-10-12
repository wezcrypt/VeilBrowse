# Deployment Guide — Backend on Ubuntu 24.04

Target: `studio.rextv.sbs` (69.169.99.137). The backup API is **additive**. It runs as its own service on `127.0.0.1:8091`, and nginx forwards only `/api/v2/` to it. Existing sites, the old Telegram bot and its files are not touched.

| Path | Purpose | Mode |
|---|---|---|
| `/opt/wezcrypt-backup/` | code + virtualenv | root, 0755 |
| `/etc/wezcrypt-backup/backup.env` | configuration (no secrets) | root:wezcrypt-backup 0640 |
| `/etc/wezcrypt-backup/token.pepper` | token-hashing secret | wezcrypt-backup 0600 |
| `/var/lib/wezcrypt-backup/backup.sqlite3` | accounts, upload sessions, item index | 0700 dir |
| `/srv/wezcrypt/iphone-backups/<user>/<collection>/` | **ciphertext only** | 0700 |

No encryption keys exist on the server. If the whole server is lost, users still need only their recovery key and a copy of `/srv/wezcrypt/iphone-backups` plus the database.

## 1. Install

```bash
git clone https://github.com/wezcrypt/VeilBrowse.git && cd VeilBrowse   # or copy the backend/ folder
sudo bash backend/deploy/install.sh --dry-run    # preview every action
sudo bash backend/deploy/install.sh              # install / upgrade (re-runnable)
```

The script:
1. copies existing config, systemd units and nginx files to `/root/wezcrypt-backup-predeploy-<timestamp>/` (and the database, on upgrades);
2. installs `python3-venv`, creates the system user `wezcrypt-backup`, the directories above and the virtualenv;
3. generates `token.pepper` once and applies database migrations;
4. installs `wezcrypt-backup.service`, `wezcrypt-backup-purge.timer` and `/usr/local/sbin/wezcrypt-backup-admin`;
5. starts the service and calls `http://127.0.0.1:8091/api/v2/health`.

## 2. nginx and TLS

Add the contents of `backend/deploy/nginx-wezcrypt-backup.conf` **inside** the existing `server { server_name studio.rextv.sbs; listen 443 ssl; … }` block, then run:

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -fsS https://studio.rextv.sbs/api/v2/health
curl -fsS https://studio.rextv.sbs/api/v2/capabilities
```

If the domain does not have a certificate yet:
```bash
sudo apt install certbot python3-certbot-nginx
sudo certbot --nginx -d studio.rextv.sbs
```
If the domain is proxied by Cloudflare, use SSL mode **Full (strict)**. Cloudflare's free plan caps request bodies at 100 MB, so keep the app's chunk size ≤ 32 MiB (the default is 16 MiB).

## 3. Create your account

```bash
sudo wezcrypt-backup-admin create-user wez            # prompts for a password (min. 12 chars)
sudo wezcrypt-backup-admin set-quota wez --gb 2000    # optional
sudo wezcrypt-backup-admin create-api-key wez --label iphone   # optional: key instead of password
sudo wezcrypt-backup-admin users
```

In the app: **Server Address** `https://studio.rextv.sbs`, **Username** `wez`, **Password** (or API key), **Remote Storage Directory** `iphone-backups`.

## 4. Operations

```bash
systemctl status wezcrypt-backup
journalctl -u wezcrypt-backup -f                # no tokens or passwords are logged
sudo wezcrypt-backup-admin backup-db /root/db-backups   # consistent SQLite snapshot
sudo wezcrypt-backup-admin purge                 # also runs hourly via the timer
sudo wezcrypt-backup-admin revoke-api-keys wez
sudo wezcrypt-backup-admin disable-user wez
```

Server-side backup of the backups: copy `/srv/wezcrypt/iphone-backups` and a `backup-db` snapshot anywhere (rsync, restic, another disk). They are already encrypted.

## 5. Rollback

```bash
sudo bash backend/deploy/rollback.sh              # uses the last pre-deploy snapshot
```
This restores code, config, systemd and nginx files. It **never** deletes `/srv/wezcrypt/iphone-backups` or the database.

## 6. Configuration (`/etc/wezcrypt-backup/backup.env`)

| Variable | Default | Meaning |
|---|---|---|
| `WZC_BACKUP_STORAGE_ROOT` | `/srv/wezcrypt/iphone-backups` | ciphertext storage |
| `WZC_BACKUP_STATE_DIR` | `/var/lib/wezcrypt-backup` | database |
| `WZC_BACKUP_TOKEN_PEPPER_FILE` | — (required) | 0600 secret file |
| `WZC_BACKUP_MAX_CHUNK_SIZE` | 32 MiB | must stay ≤ nginx `client_max_body_size` |
| `WZC_BACKUP_MAX_OBJECT_SIZE` | 64 GiB | largest single file |
| `WZC_BACKUP_MIN_FREE_BYTES` | 2 GiB | uploads are refused below this free space (HTTP 507) |
| `WZC_BACKUP_UPLOAD_TTL` | 7 days | unfinished upload sessions expire |
| `WZC_BACKUP_TOKEN_TTL` | 30 days | session lifetime |
| `WZC_BACKUP_ENABLE_DOCS` | false | serve OpenAPI at `/api/v2/openapi.json` and `/api/v2/docs` |

## 7. Verification status

The install script is syntax-checked in CI, and the service code runs under the full pytest suite and as the live backend for the iOS simulator tests. **It has not been run on the production server from this environment.** No server credentials were used or requested, and no production files were changed. Run the steps above and the `curl` checks to verify.
