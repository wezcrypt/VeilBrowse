#!/usr/bin/env bash
# Rolls back the last install: stops the backup API, restores code/config/nginx
# files from the pre-deploy backup. Encrypted backups in /srv/wezcrypt/iphone-backups
# and the database are NEVER deleted by this script.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }
BACKUP_DIR="${1:-$(cat /root/wezcrypt-backup-last-predeploy 2>/dev/null || true)}"
[[ -d "$BACKUP_DIR" ]] || { echo "no pre-deploy backup found (pass its path)" >&2; exit 1; }
echo "[rollback] using $BACKUP_DIR"
systemctl stop wezcrypt-backup 2>/dev/null || true
[[ -d "$BACKUP_DIR/opt-wezcrypt-backup" ]] && rsync -a --delete "$BACKUP_DIR/opt-wezcrypt-backup/" /opt/wezcrypt-backup/ || true
[[ -d "$BACKUP_DIR/etc-wezcrypt-backup" ]] && rsync -a "$BACKUP_DIR/etc-wezcrypt-backup/" /etc/wezcrypt-backup/ || true
for name in sites-enabled sites-available conf.d; do
  [[ -d "$BACKUP_DIR/nginx-$name" ]] && rsync -a --delete "$BACKUP_DIR/nginx-$name/" "/etc/nginx/$name/" || true
done
[[ -f "$BACKUP_DIR/wezcrypt-backup.service" ]] && cp -a "$BACKUP_DIR/wezcrypt-backup.service" /etc/systemd/system/ || true
systemctl daemon-reload
if nginx -t; then systemctl reload nginx; else echo "[rollback] nginx -t failed; inspect manually" >&2; fi
if [[ -x /opt/wezcrypt-backup/venv/bin/uvicorn ]]; then systemctl start wezcrypt-backup || true; fi
echo "[rollback] done. To remove the API entirely: systemctl disable --now wezcrypt-backup and delete the /api/v2/ nginx location."
