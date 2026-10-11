# Backend integration (Ubuntu 24.04, studio.rextv.sbs)

The native-app API is **additive**. It never edits the existing studio's code, database, files, or the `/api/files`, `/api/preview/{id}`, `/api/video/{id}` routes used by the Telegram Mini App.

## 1. Deployment options

**A. Separate service (recommended).** `backend/deploy/install.sh` installs `wezcrypt_mobile` into `/opt/wezcrypt-mobile`, keeps data in `/var/lib/wezcrypt-mobile` (its own SQLite database + encrypted objects), and runs it under systemd on `127.0.0.1:8090`. nginx sends only `/api/mobile/` there (`deploy/nginx-mobile.conf`). Rolling back = remove the nginx include and stop the service.

**B. Mount inside the existing FastAPI app.**
```python
from wezcrypt_mobile import install_mobile_api
mobile = install_mobile_api(app)   # adds /api/mobile/* and its own error handler only
```
Use a single uvicorn worker (in-process rate limits and upload locks), or run option A.

## 2. Before you start: backups
```bash
sudo tar czf /root/studio-backup-$(date +%F).tgz /path/to/existing/studio   # code + DB + config
sudo python3 -m wezcrypt_mobile backup /var/lib/wezcrypt-mobile/backups     # mobile DB (also done by install.sh)
```
Store `/etc/wezcrypt-mobile/master.keys` offline (password manager / encrypted USB). Without it WZC2 objects cannot be decrypted.

## 3. Configuration (`/etc/wezcrypt-mobile/mobile.env`)
See `deploy/mobile.env.example`. Minimum:
```
WZC_MOBILE_MASTER_KEY_FILE=/etc/wezcrypt-mobile/master.keys
WZC_MOBILE_INTERNAL_SECRET_FILE=/etc/wezcrypt-mobile/internal.secret
WZC_MOBILE_ALLOWED_TELEGRAM_IDS=<your numeric Telegram id>
WZC_MOBILE_BOT_USERNAME=<bot username without @>
```

## 4. Bot: the `/pair` command

The bot already runs on the server and receives Telegram-authenticated user ids, so it approves pairings. Add a handler (examples below), keep the existing handlers unchanged.

**python-telegram-bot (v20+)**
```python
from telegram.ext import CommandHandler
from wezcrypt_mobile.bot_integration import approve_via_http, parse_pair_command

SECRET = "/etc/wezcrypt-mobile/internal.secret"   # readable by the bot user

async def pair(update, context):
    code = parse_pair_command(update.message.text)
    if not code:
        await update.message.reply_text("Usage: /pair ABCD-EFGH (generate the code in the iPhone app)")
        return
    result = approve_via_http(code, update.effective_user.id, secret_file=SECRET)
    await update.message.reply_text(result.message)

application.add_handler(CommandHandler("pair", pair))
# Deep link t.me/<bot>?start=pair_XXXXXXXX: in your existing /start handler,
# call parse_pair_command(update.message.text) first and reuse the same logic.
```

**aiogram 3**
```python
from aiogram.filters import Command, CommandStart
from wezcrypt_mobile.bot_integration import approve_via_http, parse_pair_command

@router.message(Command("pair"))
@router.message(CommandStart(deep_link=True, magic=F.args.startswith("pair_")))
async def pair(message):
    code = parse_pair_command(message.text)
    if code:
        result = await asyncio.to_thread(approve_via_http, code, message.from_user.id, secret_file=SECRET)
        await message.answer(result.message)
```

The bot process needs read access to `internal.secret` (e.g. `chgrp <bot-group> internal.secret && chmod 640` — note the mobile service then refuses group-readable secrets unless `WZC_MOBILE_ALLOW_INSECURE_KEY_PERMS=1`; alternatively give the bot its own copy with mode 600). Without the bot change you can approve manually:
```bash
sudo -u wezcrypt-mobile env $(cat /etc/wezcrypt-mobile/mobile.env | xargs) \
  /opt/wezcrypt-mobile/venv/bin/python -m wezcrypt_mobile approve ABCD-EFGH --telegram-user-id 123456
```

## 5. Existing WZC1 files (optional)

The existing studio source was not part of this repository, so its WZC1 code was **not inspected or changed**. To show existing files in the app, expose thin wrappers around the studio's *own* functions and point the hooks at them (signatures in `wezcrypt_mobile/legacy.py`):

```python
# /opt/wezcrypt-studio/studio_bridge.py   (example — adapt names to the real studio code)
from pathlib import Path
from app.storage import list_user_files, decrypt_file_to, make_preview   # existing studio functions

def list_wzc1(telegram_user_id):
    for f in list_user_files(telegram_user_id):
        yield {"file_ref": f.id, "filename": f.name, "mime_type": f.mime, "size_bytes": f.size, "taken_at": f.created}

def open_wzc1(file_ref, telegram_user_id, destination: Path):
    decrypt_file_to(file_ref, destination)          # writes plaintext into the 0600 temp file we created

def preview_wzc1(file_ref, telegram_user_id):
    return make_preview(file_ref)                    # JPEG bytes
```
```
PYTHONPATH=/opt/wezcrypt-studio
WZC_MOBILE_LEGACY_LIST_HOOK=studio_bridge:list_wzc1
WZC_MOBILE_LEGACY_OPEN_HOOK=studio_bridge:open_wzc1
WZC_MOBILE_LEGACY_PREVIEW_HOOK=studio_bridge:preview_wzc1
```
Then index (read-only references; nothing is copied, moved or re-encrypted):
```bash
python -m wezcrypt_mobile import-legacy --telegram-user-id 123456 --dry-run
python -m wezcrypt_mobile import-legacy --telegram-user-id 123456
```
To store *new* uploads in WZC1 instead of WZC2, set `WZC_MOBILE_STORAGE_FORMAT=legacy` and `WZC_MOBILE_LEGACY_STORE_HOOK`.

## 6. Operations
```bash
python -m wezcrypt_mobile devices --telegram-user-id 123456
python -m wezcrypt_mobile revoke <device_id>
python -m wezcrypt_mobile purge          # also runs hourly via deploy/purge.timer
python -m wezcrypt_mobile backup /var/lib/wezcrypt-mobile/backups
journalctl -u wezcrypt-mobile -f
```
