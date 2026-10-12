# Architecture — WezCrypt Secure Studio

```
┌──────────────────────────── iPhone (iOS 17+) ────────────────────────────┐
│ SwiftUI screens ── AppModel (@Observable, MainActor)                     │
│   Onboarding · Dashboard · Library (Photos/Videos/Files) · Transfers     │
│   (Sync Center) · Settings (Sync, Security, About) · Restore             │
│                                                                          │
│ SyncController ── SyncEngine (actor)                                     │
│   LibraryScanner (PhotoKit, PHPersistentChangeToken, change observer)    │
│   FileImporter (Files app, security-scoped copy)                         │
│   ResourceExporter (original PHAssetResources, iCloud download)          │
│   ChunkPreparer (SHA-256 + WZCE encrypt → chunk files on disk)           │
│   QueueStore (SQLite, WAL)  ·  TransferPolicy  ·  NetworkMonitor         │
│   ChunkTransport (background URLSession, file uploads)                   │
│                                                                          │
│ Crypto: WZCE · VaultKeys · RecoveryKit · KeyVault (Secure Enclave)       │
│ Security: KeychainStore · AppLockController (LocalAuthentication)        │
│ Restore: RestoreService (download → verify → decrypt → Photos/Files)     │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ HTTPS (TLS, system trust)  — ciphertext + encrypted manifests only
┌───────────────▼────────────── Ubuntu 24.04 server ───────────────────────┐
│ nginx :443 (studio.rextv.sbs)  location /api/v2/ → 127.0.0.1:8091        │
│ wezcrypt-backup.service — FastAPI + uvicorn (dedicated user, sandboxed)  │
│   api.py (routes, validation, streaming) · auth.py (scrypt, tokens)      │
│   service.py (uploads, objects, items, quotas, audit) · db.py (SQLite)   │
│ /srv/wezcrypt/iphone-backups/<user>/<collection>/<object-id>  (0700)     │
│ /var/lib/wezcrypt-backup/backup.sqlite3 · /etc/wezcrypt-backup/          │
│ wezcrypt-backup-purge.timer (expired upload sessions, hourly)            │
└──────────────────────────────────────────────────────────────────────────┘
```

The backend is a separate service with its own user, directories, database and port. It shares nothing with the old Telegram bot or other services on the host; nginx forwards only `/api/v2/`.

## Data model

- **Object** — one WZCE ciphertext blob (an original photo, the paired video of a Live Photo, a RAW alternate, a video, a file, or an encrypted thumbnail). Id: 16 random bytes (hex).
- **Item** — one library entry. Server row: random id, kind, keyed content tag, list of object ids, and an **encrypted manifest** (WZCE blob) holding filenames, roles, UTIs, sizes, plaintext SHA-256 values, dates, dimensions and duration.
- **Vault** — per account: the public key fingerprint, so a second device with a different recovery key cannot mix data into the account.

## Sync pipeline

1. **Discovery.** First run: full PhotoKit scan in batches of 2,000 (photos and videos can be toggled separately, limited-library access is respected). Afterwards: incremental scan with `PHPersistentChangeToken` (insertions and deletions), plus a live `PHPhotoLibraryChangeObserver` while the app runs. If the token expires, the engine falls back to a full scan, and items already backed up are skipped. Files picked in the Files app are copied into private staging and queued.
   *Edits:* Photos edits are non-destructive adjustments. The engine backs up the **original** resource (`PHAssetResourceType.photo` / `.video`), so an edit does not create a new backup and the edited rendering is not stored. This is a known limitation.
2. **Queue.** Every item lives in SQLite (`QueueStore`): source id, status (`pending → preparing → uploading → finalizing → completed` / `duplicate` / `failed`), retry count, next attempt time (exponential backoff with jitter), progress, encrypted size, chunk/upload-session ids and last error. The queue survives app restarts and termination.
3. **Export.** Original resources are written to protected temp files without re-encoding: HEIC/JPEG/PNG/RAW/ProRAW DNG, RAW+JPEG alternate, Live Photo paired video, MOV/MP4/HEVC/HDR/4K/ProRes video. iCloud-only originals are downloaded.
4. **Encrypt.** Each resource is streamed through SHA-256 and WZCE (4 MiB segments) into chunk files of the configured size (8–32 MiB, default 16 MiB). Memory use is independent of file size.
5. **Duplicate check.** The keyed content tag (HMAC over kind + plaintext hashes) is checked locally and against the server (`POST /items/check`). Duplicates are marked *Already backed up* and their chunk files are deleted without uploading.
6. **Upload.** The server session for an object is opened **lazily**, right before its first chunk is sent (`POST /uploads` is idempotent per object, so racing chunks share one session). Chunk files go to a background `URLSession` as file uploads (`PUT /uploads/{id}/chunks/{n}` with `X-Chunk-SHA256`). The server is the source of truth for which chunks it has, so a resume after relaunch or network loss sends only missing chunks. Items that are re-prepared or fail cancel their server sessions (`DELETE /uploads/{id}`), so sessions never accumulate.
7. **Finalize.** `POST /uploads/{id}/complete` (server verifies object SHA-256, atomically renames), then `POST /items` with the encrypted manifest. Temp files are deleted.

## Concurrency and performance

`TransferPolicy.decide` (pure, unit-tested) computes the allowed parallel chunk uploads from settings and device conditions:

| Condition | Effect |
|---|---|
| Default | `maxConcurrency` (setting, default 4, max 8) |
| No network / Wi-Fi-only on cellular / Low Data Mode / charging-only / thermal critical / Low Power (pause mode) | Paused with a visible reason |
| Thermal `fair` / `serious` | ≤ 2 / 1 |
| Low Power Mode (not charging) | 1 |
| Battery < 20 % (not charging) | 1 |
| Cellular | ≤ 2 |

The decision is re-evaluated continuously (network path changes, thermal/power notifications). It is the **ceiling** of one global limit for every chunk request of the device:

- **Adaptive (AIMD) concurrency.** A pass starts with one upload. After a run of successes (4, then 2 × the current limit) one more is allowed, up to the ceiling. Any 429/503 halves it.
- **Server back-pressure gate.** Every response from the server passes through `ServerPressure`. On 429/503 the gate closes until `Retry-After` (seconds or HTTP date, capped at 15 min). Without `Retry-After` it closes for an exponential backoff with jitter (2 s → 5 min) that grows with consecutive signals. While the gate is closed, no chunk, session or preparation request is sent. Chunks hit by back-pressure are **deferred without counting an attempt**, so a busy server never turns into failed files, and there is no retry storm.
- **Bounded preparation.** At most 24 items / 512 MB are encrypted ahead of the upload.
- **Real failures.** Failed chunks retry with exponential backoff and jitter (2 s → 5 min), at most 16 times. Failed items retry up to 8 times and then land in *Failed* with the server's reason; *Retry Failed* re-queues them.

Speed is shown live (10 s window). The time estimate uses the remaining **bytes** (measured sizes, or the per-kind average for photos not read yet) divided by the 2-minute average speed. The UI is refreshed at most twice per second (every 2 s in the background). Defaults (4 parallel, 16 MiB chunks) come from the CI benchmark `testUploadConcurrencyAndChunkSizeBenchmark`. It runs against a loopback server, so it measures CPU and encryption cost but not real Wi-Fi or cellular behaviour. Real-network tuning has to be done on a device; the settings expose both values.

## Background execution — what iOS actually allows

| Mechanism | What it does here | Limits imposed by iOS |
|---|---|---|
| Background `URLSession` | Chunk uploads keep transferring after the app is suspended. When the app leaves the foreground, the transport switches to *detach* mode (ending the granted background time no longer cancels transfers), and up to 48 ready chunks / 768 MB are **handed to iOS** before suspension. When they finish, iOS wakes the app (`handleEventsForBackgroundURLSession`). The app reconciles them with the server, encrypts the next items for ~18 s and hands off the next batch. | Chunks must already be encrypted on disk. iOS schedules transfers (discretionary on cellular/low power) and decides how often the app is woken. **Force-quitting the app from the app switcher cancels all its background transfers** until it is opened again. |
| `BGProcessingTask` | Opportunistic pass: incremental scan, export, encrypt, enqueue. Requests network; optionally external power. | iOS decides when (typically overnight, charging, on Wi-Fi). Minutes, not hours. Not after a force-quit until the user opens the app again. |
| `BGAppRefreshTask` | Short pass to pick up new photos. | Seconds; frequency is learned from how often the user opens the app. |
| PhotoKit change observer | Queues new photos immediately while the app is running. | Does not wake a suspended app. |

There is **no** continuous background sync on iOS and this app does not try to fake one (no silent audio, no location tricks). The `audio` background mode is declared only so a video started in Picture in Picture keeps playing. New photos are guaranteed to be picked up the next time the app is opened. Between openings, uploads continue only as far as the mechanisms above allow.

## Viewer and player

- **Photos**: full-screen pager (swipe), pinch and double-tap zoom (`UIScrollView`), tap to hide the controls, portrait and landscape. A page first shows the cached thumbnail, then the decrypted original decoded at screen size. Zooming in re-decodes at up to 5,000 px. Formats: whatever ImageIO decodes (HEIC, JPEG, PNG, WebP, DNG previews, GIF). Live Photos play from their backed-up photo + paired video (`PHLivePhoto`). Info, share (original bytes) and save to Photos (original resources, SHA-256 verified).
- **Videos**: `AVPlayer` with custom controls: scrubber, ±10 s, 0.5/1/1.25/1.5/2×, mute and volume, Picture in Picture, previous/next, resume position, embedded subtitle tracks and external `.srt`/`.vtt` from Files (UTF-8 or Windows-1256). Formats: what AVFoundation plays (H.264, HEVC, ProRes, MOV, MP4).
- **Decryption model**: the encrypted original is downloaded (with progress) into `MediaCache`, which stores **ciphertext only** (LRU, 1 GB) and also serves thumbnails, decrypted in memory. For viewing, the object is decrypted on the device into a protected temporary file, verified against the manifest SHA-256, and only then opened. Encrypted data is never handed to `AVPlayer`. **There is no encrypted streaming**: a video plays after it has been downloaded and decrypted completely. Decrypted files are deleted when the page closes, at launch, on sign-out, and when the device locks.

## Restore

`RestoreService` lists items (paged), decrypts manifests locally, downloads objects (HTTP Range supported), decrypts segment by segment into protected temp files, verifies the plaintext SHA-256 from the manifest, and then:
- photos/videos → `PHAssetCreationRequest` with the original resources (Live Photos are recreated from photo + paired video; RAW+JPEG pairs keep both);
- files → share sheet / Files export.

`backend/tools/wezcrypt_restore.py` does the same on any computer with Python 3.10+ (see [RECOVERY.md](RECOVERY.md)).

## HTTP API (`/api/v2`)

| Function | Method & path | Auth |
|---|---|---|
| Health | `GET /health` | – |
| Server capabilities | `GET /capabilities` | – |
| Upload health (counts only) | `GET /stats` | token |
| Login / logout | `POST /auth/login`, `POST /auth/logout` | – / token |
| Account & storage usage | `GET /me` | token |
| Vault fingerprint | `GET /vault`, `PUT /vault` | token |
| Create upload session | `POST /uploads` | token |
| Upload chunk | `PUT /uploads/{id}/chunks/{index}` (`X-Chunk-SHA256`) | token |
| Upload progress | `GET /uploads/{id}` | token |
| Complete / cancel | `POST /uploads/{id}/complete`, `DELETE /uploads/{id}` | token |
| Download encrypted object | `GET|HEAD /objects/{id}` (Range) | token |
| Delete object | `DELETE /objects/{id}` | token |
| Register item | `POST /items` | token |
| Duplicate check | `POST /items/check` | token |
| List / get items | `GET /items`, `GET /items/{id}` | token |
| Delete backup | `DELETE /items/{id}` + `X-WZC-Confirm-Delete: yes` | token |

Errors use `{"error": {"code": "...", "message": "..."}}`. With `WZC_BACKUP_ENABLE_DOCS=true` the OpenAPI schema is served at `/api/v2/openapi.json` and Swagger UI at `/api/v2/docs`. It is off by default in production.

## SFTP

The brief lists SFTP as an optional transport. **It is not implemented.** iOS has no system SSH/SFTP API, so SFTP would require bundling a third-party SSH stack (for example the Swift package *Citadel*), host-key pinning UI and a separate code path without server-side chunk verification. The encryption model would not change, because files are encrypted before any transport sees them. HTTPS was finished and tested first. SFTP can be added later as a second `Transport` implementation behind the same queue.
