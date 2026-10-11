#!/usr/bin/env bash
# Installs the native-app API next to the existing studio on Ubuntu 24.04.
# Idempotent; never touches the existing studio, its database or its files.
set -euo pipefail

APP_DIR=/opt/wezcrypt-mobile
DATA_DIR=/var/lib/wezcrypt-mobile
CONF_DIR=/etc/wezcrypt-mobile
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ $EUID -ne 0 ]]; then echo "run as root" >&2; exit 1; fi

log() { printf '[install] %s\n' "$*"; }

apt-get install -y --no-install-recommends python3-venv rsync curl >/dev/null
id wezcrypt-mobile >/dev/null 2>&1 || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin wezcrypt-mobile

install -d -m 0755 "$APP_DIR"
install -d -m 0700 -o wezcrypt-mobile -g wezcrypt-mobile "$DATA_DIR"
install -d -m 0750 -o root -g wezcrypt-mobile "$CONF_DIR"

log "copying service code"
rsync -a --delete --exclude tests --exclude '__pycache__' "$SRC_DIR/" "$APP_DIR/src/"
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet "$APP_DIR/src"

if [[ ! -f "$CONF_DIR/master.keys" ]]; then
  log "generating master keyring (BACK IT UP OFFLINE)"
  "$APP_DIR/venv/bin/python" -m wezcrypt_mobile generate-key "$CONF_DIR/master.keys"
fi
if [[ ! -f "$CONF_DIR/internal.secret" ]]; then
  "$APP_DIR/venv/bin/python" -m wezcrypt_mobile generate-secret "$CONF_DIR/internal.secret"
fi
chown wezcrypt-mobile:wezcrypt-mobile "$CONF_DIR/master.keys" "$CONF_DIR/internal.secret"
chmod 600 "$CONF_DIR/master.keys" "$CONF_DIR/internal.secret"

if [[ ! -f "$CONF_DIR/mobile.env" ]]; then
  install -m 0600 "$SRC_DIR/deploy/mobile.env.example" "$CONF_DIR/mobile.env"
  log "edit $CONF_DIR/mobile.env (allowed Telegram ids, bot username) then re-run"
fi

if [[ -f "$DATA_DIR/mobile.sqlite3" ]]; then
  backup="$DATA_DIR/backups"
  install -d -m 0700 -o wezcrypt-mobile -g wezcrypt-mobile "$backup"
  log "backing up database before migrations"
  sudo -u wezcrypt-mobile env $(grep -v '^#' "$CONF_DIR/mobile.env" | xargs) \
    "$APP_DIR/venv/bin/python" -m wezcrypt_mobile backup "$backup"
fi
sudo -u wezcrypt-mobile env $(grep -v '^#' "$CONF_DIR/mobile.env" | xargs) \
  "$APP_DIR/venv/bin/python" -m wezcrypt_mobile migrate

install -m 0644 "$SRC_DIR/deploy/wezcrypt-mobile.service" /etc/systemd/system/wezcrypt-mobile.service
systemctl daemon-reload
systemctl enable --now wezcrypt-mobile
systemctl restart wezcrypt-mobile
sleep 1
curl -fsS http://127.0.0.1:8090/api/mobile/health && echo
log "done. Add deploy/nginx-mobile.conf to the studio server block, run 'nginx -t' and reload nginx."
