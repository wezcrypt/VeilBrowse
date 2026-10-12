# Recovery Guide

Everything stored on the server is encrypted with keys derived from your **recovery key**. The server never has it.

> **Recovery key + server account = your data.** Lose the recovery key and every device that holds it, and the backups cannot be decrypted by anyone. There is no reset.

## The recovery key

- 55 characters in 11 groups of five, e.g. `7K2QM-…-R4D9X` (Crockford Base32: `O` = `0`, `I`/`L` = `1`; case and dashes are ignored).
- It contains a 16-bit checksum, so a typo is reported as *"contains a typo"* instead of producing a wrong key.
- Store it **offline**: on paper in a safe place, or in a password manager you trust. Do not keep it only on the phone.
- **Settings → Security → Show Recovery Key** displays it again after Face ID / passcode.

## Restore on a new iPhone

1. Install the app (see [INSTALLATION.md](INSTALLATION.md)).
2. Connect to the same server and account.
3. In **Encryption Setup** choose **I already have a recovery key** and enter it.
   - The app derives the vault fingerprint and compares it with the one stored on the server. A different key is rejected before anything is written.
4. Open **Library** to browse Photos, Videos and Files (decrypted on the phone).
5. **Restore**: restore selected items or everything. Photos and videos go back into the Photos library with their original resources (Live Photos as Live Photos, RAW+JPEG pairs together). Files go to the share sheet / Files app.
6. Every restored resource is checked against the SHA-256 recorded in its encrypted manifest before it is saved. A mismatch is reported as corrupted and is not saved.

## Restore on a computer (no iPhone)

Requires Python 3.10+ and the `cryptography` package:

```bash
pip install cryptography
cd backend/tools
python3 wezcrypt_restore.py --server https://studio.rextv.sbs --username wez --out ./restored
# prompts for the server password and the recovery key (input hidden)
# options: --collection iphone-backups  --include-thumbnails  -v
#          --api-key-stdin / --recovery-key-stdin for scripted use
```

The tool downloads each object, authenticates every segment, verifies the plaintext SHA-256 from the manifest, and writes files under their original names (Live Photos as photo + `.MOV`).

## Restore without the server software

If the server is gone but you have a copy of `/srv/wezcrypt/iphone-backups`:
- each object file is a self-contained WZCE container (see [SECURITY.md](../SECURITY.md) §4);
- `backend/tools/wzce.py` can decrypt any object with the recovery key, but the original filenames are in the item manifests stored in the database. Keep `backup-db` snapshots together with the storage copy, or restore both onto a new server and use the normal tools.

## Detecting corruption

| Symptom | Meaning |
|---|---|
| "Wrong recovery key, or the encrypted file header is corrupted." | key unwrap failed |
| "Encrypted data is corrupted or out of order (segment N)." | segment N was modified, swapped or reordered |
| "The encrypted file is incomplete." / "unexpected trailing data" | truncated or extended file |
| "The encrypted file belongs to a different item." | object moved between items |
| Integrity error after decryption | plaintext SHA-256 differs from the manifest |
| "N items could not be decrypted with this recovery key" (Library) | manifests from a different key, or damaged |

## Changing the recovery key

Rotation is designed but not implemented yet (see [SECURITY.md](../SECURITY.md) §8). If the key is exposed today, the safe procedure is: create a new account on the server → set up a new recovery key → back up again → delete the old account's data with `DELETE /items/{id}` (in-app delete) or on the server.
