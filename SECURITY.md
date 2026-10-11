# Security Model — WezCrypt Secure Studio

This document states what the system protects against and, just as important, what it does **not**.

## 1. Summary

| Property | Status |
|---|---|
| Transport encryption | HTTPS only (TLS ≥ 1.2, system trust store, no ATS exceptions, no custom/untrusted certificates) |
| Encryption at rest on server (new uploads) | **WZC2**: AES-256-GCM, random 256-bit data key per file, wrapped by a server master key |
| Encryption at rest on server (existing files) | **WZC1** (existing studio format) — untouched, read via hooks |
| End-to-end encryption | **No.** The server holds the master key and can decrypt. |
| Device authentication | Per-device P-256 key in the Secure Enclave; pairing approved through the Telegram bot |
| App lock | Face ID / Touch ID / passcode (`LAPolicy.deviceOwnerAuthentication`) |
| Secrets in the app | None: no bot token, no server keys, no passwords |

## 2. Threat model

**Protected against**
- Network attackers (TLS; tokens are never placed in URLs).
- Theft of the server disk or backups *without* the keyring file (`/etc/wezcrypt-mobile/master.keys` is separate from data in `/var/lib/wezcrypt-mobile`).
- Stolen refresh tokens: refresh requires an ECDSA signature from the device's Secure Enclave key.
- Refresh-token replay: rotation with reuse detection (a reused token after a 60 s grace window revokes the device).
- Tampering, truncation, reordering of stored objects (GCM tags bind header, segment index and final flag).
- Casual access to an unlocked phone: app lock + privacy cover in the app switcher.
- Cross-user access: every query is scoped by the authenticated user id.

**Not protected against**
- A compromised server or operator with access to the keyring: they can decrypt everything (no E2EE).
- A fully compromised (jailbroken) device while the vault is unlocked.
- Telegram account takeover: whoever controls the allowed Telegram account can pair a new device. Restrict `WZC_MOBILE_ALLOWED_TELEGRAM_IDS` and review *Settings → Security → Linked Devices*.

## 3. Authentication

1. App creates a fresh P-256 key (Secure Enclave on hardware, Keychain on simulator) and calls `POST /api/mobile/pair/start` with the public key.
2. Server returns an 8-character code (≈40 bits, 5-minute TTL, single use; stored only as an HMAC) plus a pairing id and a poll secret.
3. The owner sends `/pair CODE` (or taps the `t.me/<bot>?start=pair_CODE` link). The **bot**, which receives a Telegram-authenticated user id, approves the code over loopback (`/api/mobile/internal/pair/approve`, shared secret + loopback-only + blocked in nginx) or in-process.
4. The app polls and receives its first tokens exactly once.

Tokens: opaque random strings, stored server-side only as HMAC-SHA256(pepper, token). Access tokens live 15 minutes, refresh tokens 30 days. Signing out or revoking a device invalidates all its tokens and cancels its uploads. Telegram `initData` is never used by the native app.

Rate limits (in-process): pair start 10/10 min per IP, poll 120/10 min per pairing, approve 10/h per Telegram user, refresh 30/10 min per device.

## 4. Storage format (WZC2)

```
header (89 B): "WZC2" | ver | segment_size | key_id | wrap_nonce(12) | wrapped_dek(48) | nonce_prefix(8) | plaintext_size
segment i:     AES-256-GCM(dek, data_i, nonce = prefix‖u32(i), aad = header‖u32(i)‖u8(final))
```
- Chunks are encrypted **as they arrive**; plaintext of WZC2 uploads is never written to disk.
- Whole-file SHA-256 is verified at completion by streaming decryption; mismatches are discarded.
- Range requests decrypt only the touched 1 MiB segments (video seeking without full decryption).
- Key rotation: add a new `id:key` line, set `WZC_MOBILE_ACTIVE_KEY_ID`; old objects stay readable by key id.
- Swift and Python implementations are verified byte-for-byte by a shared test vector.

**WZC1 compatibility.** The existing studio code was not available in this repository, so WZC1 was **not** re-implemented, modified or assumed. Existing files are read through `WZC_MOBILE_LEGACY_OPEN_HOOK` (calls the studio's own decrypt), decrypted into a 0600 short-TTL cache for range serving, then purged. With `WZC_MOBILE_STORAGE_FORMAT=legacy`, new uploads are handed to the studio's own encrypt function instead. Deleting a legacy entry from the app removes only the index row, never the WZC1 object.

## 5. On the device

- Session tokens and the device key handle: Keychain, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (not synced, not restorable to another device; available to background uploads after first unlock).
- Thumbnail cache: WZC2-encrypted with a random Keychain key. Sign-out destroys the key, making the cache unreadable, and deletes it.
- Full-resolution photos: downloaded to a `NSFileProtectionComplete` temp file, decoded, deleted immediately. Videos stream from memory only.
- Exported originals for upload: temp files deleted after each upload; leftovers wiped at launch.
- Logging: `os.Logger`; tokens, keys, signatures, codes and poll secrets are never logged; identifiers use `privacy: .private`.
- Nothing is ever deleted from the Photos library.

## 6. Server hardening

- Separate systemd service, dedicated user, `UMask=0077`, `ProtectSystem=strict`, `NoNewPrivileges`, empty capability set.
- Key/secret files must be mode 600 or the service refuses to start.
- Limits: JSON bodies 1 MiB, chunks 8 MiB, thumbnails 2 MiB, files 20 GiB (configurable), 64 concurrent uploads per device, expired upload parts purged hourly.
- Strict request validation (`extra="forbid"`), sanitized filenames, parameterized SQL only, explicit `X-WZC-Confirm-Delete: yes` for permanent deletion.
- Install script backs up the database before migrations; migrations are additive and isolated in their own database.

## 7. Planned: client-side (end-to-end) encryption

Building blocks already exist in `ios/.../Core/Crypto` (`WZC2` with `clientKeyID = 0xFFFFFFFF`, `RecoveryKit`, unit-tested):

1. On opt-in, the app generates a 256-bit **vault key** (Keychain, this-device-only) and a 256-bit **recovery key** displayed once as 55 Crockford-Base32 characters with a checksum; the user must confirm it was saved.
2. Each file is WZC2-encrypted on the phone with a random data key wrapped by the vault key; the server stores opaque blobs (no server thumbnails — thumbnails are encrypted the same way).
3. The vault key, wrapped with `HKDF(recovery key)`, is uploaded as an escrow blob the server cannot open.
4. New devices obtain the vault key from an existing device (ECDH between Secure Enclave keys, approved in-app) or from the recovery key.
5. Losing all devices **and** the recovery key means data loss — by design, explained before enabling.
6. Existing server-encrypted files can be re-encrypted client-side in the background; WZC1/WZC2 server objects are deleted only after the client copy is verified.

Until this ships, the app and documentation describe the system as server-side encrypted only.

## 8. Reporting

Report vulnerabilities privately via https://wezcrypt.com. Do not open public issues for security problems.
