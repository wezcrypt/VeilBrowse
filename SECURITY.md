# Security Model — WezCrypt Secure Studio

This document describes what the system protects, how, and what it does **not** protect.
It describes the code in this repository; anything not implemented is labelled as such.

## 1. Summary

| Property | Implementation |
|---|---|
| Encryption location | **On the iPhone, before upload** (end-to-end). The server never receives plaintext or keys. |
| Cipher | AES-256-GCM (CryptoKit on iOS, `cryptography` in the Python tools) |
| Per-file keys | Fresh random 256-bit data key (DEK) for every object |
| Key hierarchy | Recovery key → HKDF-SHA256 → file-wrap key, dedup key, fingerprint key |
| Container format | **WZCE v1**, versioned, segmented, header-bound (§4) |
| Metadata | Filenames, capture dates, dimensions, durations, plaintext hashes are inside an **encrypted manifest** |
| Recovery key at rest on the phone | Sealed under a Secure Enclave P-256 key (hardware), Keychain `AfterFirstUnlockThisDeviceOnly` |
| Server credentials on the phone | Keychain only; never UserDefaults, files or logs |
| Transport | HTTPS with the system trust store; no ATS exceptions, no certificate overrides |
| App lock | Face ID / Touch ID / passcode, privacy cover in the app switcher |
| Third parties | None: no analytics, no crash reporters, no cloud image recognition, no Telegram |

## 2. Threat model

**Protected against**
- A compromised server, a malicious operator, theft of server disks or backups: they hold only WZCE ciphertext and encrypted manifests.
- Network attackers: TLS with system validation (tested against expired, self-signed, untrusted-root and wrong-host certificates).
- Tampering with stored data: each segment is authenticated with GCM and bound to the object id, sizes, segment index and the final-segment flag. Swapping, reordering, truncating, appending or moving segments between files is detected.
- Corrupted uploads: per-chunk and whole-object SHA-256 of the ciphertext are verified by the server before finalization; the app re-verifies the plaintext SHA-256 recorded in the manifest after decryption.
- Casual access to an unlocked phone: app lock and privacy cover.
- Cross-account access: every query is scoped by the authenticated user id.

**Not protected against**
- A fully compromised (jailbroken or malware-infected) iPhone while the app is unlocked.
- Loss of the recovery key **and** every device that holds it — the data is then unrecoverable by design. Nobody, including the server operator, can reset it.
- Traffic analysis (see §6).
- Someone who has the recovery key: it is the master secret. Keep it offline.

## 3. Key hierarchy

```
Recovery key (256-bit random, shown once as 55 Crockford-Base32 chars + 16-bit checksum)
 ├─ HKDF-SHA256(salt "WezCrypt-Vault-v1", info "wzce/file-wrap")   → file-wrap key
 │    └─ AES-GCM wraps each object's random DEK (stored in the WZCE header)
 ├─ HKDF-SHA256(..., info "wzce/dedup")                              → dedup key
 │    └─ HMAC-SHA256 content tag (server-side duplicate detection without plaintext hashes)
 └─ HKDF-SHA256(..., info "wzce/fingerprint")                        → fingerprint key
      └─ HMAC over a constant → public vault fingerprint (stops a second device from
         writing into the same account with a different key; reveals nothing about the key)
```

- Randomness: `SymmetricKey(size:)` / `SecRandomCopyBytes` on iOS, `secrets` / `os.urandom` in Python.
- The recovery key is never sent to the server. Only the fingerprint is.
- **On the iPhone** the recovery key is AES-GCM sealed under a key derived (ECDH + HKDF) from a P-256 key that lives in the **Secure Enclave** and cannot be exported. The Keychain stores only the sealed blob and the enclave key's device-bound handle, with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (never in iCloud Keychain, never restored to another device, available to background uploads after the first unlock). Simulators lack a Secure Enclave and fall back to the Keychain.
- Swift and Python derive identical keys; this is checked by a shared test vector (`testKeyDerivationMatchesPython`, `test_wzce.py`).

## 4. WZCE v1 container

```
header (104 bytes)
  "WZCE" | version=1 | alg=1 (AES-256-GCM) | flags u16
  | segment_size u32 | plaintext_size u64 | object_id (16) | nonce_prefix (8)
  | key_nonce (12) | wrapped_dek (32 + 16 tag)

segment i (i = 0 … n-1)
  AES-256-GCM(DEK, plaintext_i,
              nonce = nonce_prefix ‖ u32_be(i),
              aad   = header(104) ‖ u32_be(i) ‖ u8(is_final))
```

- `wrapped_dek = AES-GCM(file-wrap key, DEK, nonce = key_nonce, aad = header_prefix)` where `header_prefix` is the first 44 header bytes, so the wrapped key is bound to the object id and sizes.
- Nonces: the DEK is unique per object and the 64-bit prefix is random, so `(key, nonce)` pairs never repeat; within an object the counter is the segment index.
- Default segment size 4 MiB. Encryption and decryption stream segment by segment — memory stays bounded regardless of file size (`testEncryptionMemoryStaysBounded`).
- Decryption fails closed with a specific error: malformed header, unsupported version, wrong object, key unwrap failure (wrong recovery key), segment authentication failure (index reported), truncation, trailing data.
- Manifests use the same container with `object_id = item id`.
- The format is versioned: a future v2 can be added without breaking v1 reads.

## 5. Upload pipeline and integrity

1. Export the original resource from PhotoKit (no re-encoding) to a protected temp file.
2. Stream it through SHA-256 (plaintext hash → goes into the encrypted manifest) and WZCE encryption into chunk files on disk.
3. SHA-256 of each ciphertext chunk and of the whole ciphertext object are sent with the upload session.
4. The server verifies each chunk hash on receipt and the object hash on completion, then atomically renames it into place. A mismatch discards the upload.
5. After restore, the app and the desktop tool recompute the plaintext SHA-256 and compare it with the manifest before writing the final file.

## 6. What the server can see

The server sees **operational data only**:

| Visible | Not visible |
|---|---|
| Username, login IP, session/API-key metadata | Recovery key, any derived key, any DEK |
| Number of items, item kind (`photo`/`video`/`livePhoto`/`file`) | File contents |
| Ciphertext sizes (≈ plaintext size + 48 B header overhead + 16 B per 4 MiB) | Filenames, capture dates, locations, dimensions, durations |
| Upload times (server clock), collection name (default `iphone-backups`) | Plaintext SHA-256 (only a keyed HMAC tag) |
| Random object/item ids, ciphertext SHA-256 | Thumbnails (encrypted like originals) |

Sizes and timing can leak coarse information (e.g. "a 2 GB video was uploaded at 21:00"). Padding is not implemented because it would cost storage and bandwidth on every file.

## 7. Authentication and server hardening

- Accounts are created on the server with the CLI (`create-user`, `create-api-key`). Passwords are hashed with scrypt; session tokens and API keys are random and stored only as `HMAC-SHA256(pepper, token)`.
- Sessions expire (default 30 days); logout revokes immediately. Login is rate limited (8 attempts / 15 min per user+IP).
- Request validation with strict Pydantic models (`extra="forbid"`), id formats enforced, collection names restricted to `[A-Za-z0-9_.-]`, no client-supplied paths reach the filesystem (no path traversal).
- Fair use per user: at most 8 chunk uploads received at once (more get `429` + `Retry-After`), open upload sessions capped and abandoned empty sessions reclaimed. `GET /api/v2/stats` and `wezcrypt-backup-admin stats` expose counts only (no ids, names or content).
- Upload quotas per user, minimum free disk reserve, max object/chunk sizes, max active uploads, upload session expiry with an hourly purge timer.
- Atomic finalization (`fsync` + rename) after hash verification.
- Permanent deletion requires the header `X-WZC-Confirm-Delete: yes`.
- Audit log (`audit` table) of logins, failed logins, account changes, stored objects and deletions — random ids and sizes only, never tokens, passwords or plaintext data.
- systemd sandbox: dedicated user, `ProtectSystem=strict`, `NoNewPrivileges`, `UMask=0077`, no capabilities. The pepper file must be mode 600 or the service refuses to start.
- The API is served only on `127.0.0.1:8091`; nginx terminates TLS.

## 8. Key rotation

- **Data keys**: every object already has its own DEK.
- **Recovery key rotation** (design, not yet exposed in the UI): generate a new recovery key → for each object, unwrap the DEK with the old file-wrap key and re-wrap with the new one, rewriting only the 104-byte header (no re-encryption of the payload) → re-seal every manifest → `PUT /api/v2/vault` with the new fingerprint after all objects are migrated. Because the server only accepts a fingerprint change for an empty vault today, rotation requires a server endpoint for header replacement. This is documented, not implemented.
- **Server pepper rotation**: replacing the pepper file invalidates all sessions and API keys (users log in again). Stored data is unaffected.

## 9. On the device

- Exported originals and chunk files live in the app container with `NSFileProtectionCompleteUntilFirstUserAuthentication`, are excluded from iCloud backup, and are deleted once the server confirms the object. Leftovers are wiped at launch.
- Restored files are decrypted into a protected temp directory, verified, handed to Photos/Files, then deleted.
- Viewer: the on-disk media cache (`Caches/EncryptedMedia`, 1 GB LRU) holds **ciphertext only**. Thumbnails are decrypted in memory. Originals opened in the viewer or player are decrypted into `NSFileProtectionComplete` files that are deleted when the page closes, at launch, on sign-out and when the device locks. Playback positions are stored per random item id (no names or content).
- Logs use `os.Logger`; identifiers and filenames are `privacy: .private`; tokens, passwords and keys are never logged.
- Nothing is ever deleted from the Photos library.

## 10. Reporting

Report vulnerabilities privately via https://wezcrypt.com. Do not open public issues for security problems.
