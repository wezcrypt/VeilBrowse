#!/usr/bin/env bash
# Installs or upgrades the WezCrypt encrypted backup API on Ubuntu 24.04.
# Safe by design: backs up every file it touches, never edits the bot/studio,
# never runs the service as root. Re-runnable.
#
#   sudo bash backend/deploy/install.sh            # install / upgrade
#   sudo bash backend/deploy/install.sh --dry-run  # show what would happen
set -euo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

APP_DIR=/opt/wezcrypt-backup
STATE_DIR=/var/lib/wezcrypt-backup
STORAGE=/srv/wezcrypt/iphone-backups
CONF_DIR=/etc/wezcrypt-backup
SRC="$(cd "$(dirname "$0")/.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR=/root/wezcrypt-backup-predeploy-$STAMP

log() { printf '[install] %s\n' "$*"; }
run() { if (( DRY_RUN )); then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

log "pre-deploy backup -> $BACKUP_DIR"
run install -d -m 0700 "$BACKUP_DIR"
backup_copy() { [[ -e "$1" ]] && run cp -a "$1" "$BACKUP_DIR/$2" || true; }
backup_copy "$APP_DIR" opt-wezcrypt-backup
backup_copy "$CONF_DIR" etc-wezcrypt-backup
backup_copy /etc/systemd/system/wezcrypt-backup.service wezcrypt-backup.service
backup_copy /etc/nginx/sites-enabled nginx-sites-enabled
backup_copy /etc/nginx/sites-available nginx-sites-available
backup_copy /etc/nginx/conf.d nginx-conf.d
if [[ -f "$STATE_DIR/backup.sqlite3" && -x "$APP_DIR/venv/bin/python" ]]; then
  log "backing up database"
  run sudo -u wezcrypt-backup env $(grep -v '^#' "$CONF_DIR/backup.env" | xargs) "$APP_DIR/venv/bin/python" -m wezcrypt_backup backup-db "$BACKUP_DIR"
fi
(( DRY_RUN )) || echo "$BACKUP_DIR" > /root/wezcrypt-backup-last-predeploy

run apt-get install -y --no-install-recommends python3-venv rsync curl >/dev/null
id wezcrypt-backup >/dev/null 2>&1 || run useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin wezcrypt-backup
run install -d -m 0755 "$APP_DIR"
run install -d -m 0700 -o wezcrypt-backup -g wezcrypt-backup "$STATE_DIR"
run install -d -m 0755 /srv/wezcrypt
run install -d -m 0700 -o wezcrypt-backup -g wezcrypt-backup "$STORAGE"
run install -d -m 0750 -o root -g wezcrypt-backup "$CONF_DIR"

log "installing code"
run rsync -a --delete --exclude tests --exclude __pycache__ "$SRC/" "$APP_DIR/src/"
run python3 -m venv "$APP_DIR/venv"
run "$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
run "$APP_DIR/venv/bin/pip" install --quiet "$APP_DIR/src"

if [[ ! -f "$CONF_DIR/backup.env" ]]; then
  run install -m 0640 -o root -g wezcrypt-backup "$SRC/deploy/backup.env.example" "$CONF_DIR/backup.env"
fi
if [[ ! -f "$CONF_DIR/token.pepper" ]]; then
  run "$APP_DIR/venv/bin/python" -m wezcrypt_backup generate-pepper "$CONF_DIR/token.pepper"
  run chown wezcrypt-backup:wezcrypt-backup "$CONF_DIR/token.pepper"
fi

run sudo -u wezcrypt-backup env $(grep -v '^#' "$SRC/deploy/backup.env.example" | xargs) \
  "$APP_DIR/venv/bin/python" -m wezcrypt_backup migrate

run install -m 0755 "$SRC/deploy/wezcrypt-backup-admin" /usr/local/sbin/wezcrypt-backup-admin
run install -m 0644 "$SRC/deploy/wezcrypt-backup.service" /etc/systemd/system/
run install -m 0644 "$SRC/deploy/wezcrypt-backup-purge.service" /etc/systemd/system/
run install -m 0644 "$SRC/deploy/wezcrypt-backup-purge.timer" /etc/systemd/system/
run systemctl daemon-reload
run systemctl enable --now wezcrypt-backup wezcrypt-backup-purge.timer
run systemctl restart wezcrypt-backup
(( DRY_RUN )) || { sleep 1; curl -fsS http://127.0.0.1:8091/api/v2/health; echo; }

log "next: add deploy/nginx-wezcrypt-backup.conf to the studio.rextv.sbs server block, then: nginx -t && systemctl reload nginx"
log "create your account: sudo wezcrypt-backup-admin create-user <name>"
log "rollback: sudo bash $SRC/deploy/rollback.sh"
