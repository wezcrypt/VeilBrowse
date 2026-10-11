# WezCrypt Mobile API v1

Base: `https://studio.rextv.sbs/api/mobile`. JSON uses snake_case; timestamps are UNIX seconds. Authenticated routes need `Authorization: Bearer <access_token>`. Errors:
```json
{"error": {"code": "offset_mismatch", "message": "...", "offset": 8388608}}
```

## Pairing & session
| Method | Path | Auth | Body → Response |
|---|---|---|---|
| GET | `/health` | – | `{status, api_version}` |
| POST | `/pair/start` | – | `{device_name, device_model, system_version, public_key}` (base64 DER P-256) → `{pairing_id, code, poll_secret, expires_at, poll_interval, bot_username, telegram_link}` |
| POST | `/pair/poll` | – | `{pairing_id, poll_secret}` → `{status: pending\|approved\|expired\|consumed, session?}` (session returned once) |
| POST | `/internal/pair/approve` | loopback + `X-WZC-Internal-Secret` | `{code, telegram_user_id}` → `{device_name, device_model}` — blocked by nginx |
| POST | `/session/refresh` | device signature | `{device_id, refresh_token, timestamp, signature}` → session |
| POST | `/session/logout` | ✓ | revokes current device → 204 |
| GET | `/devices` | ✓ | `{devices: [...]}` |
| DELETE | `/devices/{id}` | ✓ | 204 |
| GET | `/account` | ✓ | counts, bytes, encryption description (`end_to_end: false`), limits |

Session: `{device_id, access_token, access_expires_at, refresh_token, refresh_expires_at}`.
Refresh signature: ECDSA-P256-SHA256 (DER, base64) over
`"WZC-REFRESH-V1\n{device_id}\n{timestamp}\n{sha256_hex(refresh_token)}"`; timestamp within ±300 s.

## Uploads (resumable)
| Method | Path | Notes |
|---|---|---|
| POST | `/sync/check` | `{sha256: [...≤2000]}` → `{existing: {sha: media_id}}` |
| POST | `/uploads` | `{filename, mime_type, media_type, size_bytes, sha256, taken_at?, width?, height?, duration_ms?, is_favorite, is_screenshot}` → `{status:"duplicate", media}` or `{status:"created", upload_id, offset, chunk_size, segment_size, expires_at}`. Re-posting the same sha resumes the active session. |
| GET | `/uploads/{id}` | current `offset`, `status` |
| PATCH | `/uploads/{id}` | raw bytes; headers `Upload-Offset`, `Upload-Checksum: sha256 <base64>`. Non-final chunks must be multiples of `segment_size`; max `chunk_size`. → `{offset}`. 409 `offset_mismatch` carries the server offset. |
| POST | `/uploads/{id}/complete` | verifies whole-file SHA-256 → `{media}`; 422 `hash_mismatch` |
| DELETE | `/uploads/{id}` | cancel |

## Library & media
| Method | Path | Notes |
|---|---|---|
| GET | `/library` | `cursor, limit≤500, type=photo\|video, favorite, screenshot, q, from, to, album_id, added_since, sort=taken\|added` → `{items, next_cursor}` (keyset pagination) |
| GET | `/library/summary` | `granularity=day\|month\|year, tz_offset_minutes, before, limit, type` → `{buckets:[{key,count,total_bytes,cover_media_id,start,end}], next_before}` |
| GET | `/media/{id}` | item + `album_ids` |
| PATCH | `/media/{id}` | `{filename?, is_favorite?}` |
| POST | `/media/favorite` | `{media_ids, is_favorite}` |
| POST | `/media/delete` | `{media_ids}` + header `X-WZC-Confirm-Delete: yes` (WZC1 objects are never deleted) |
| GET/PUT | `/media/{id}/thumbnail` | JPEG/PNG ≤ 2 MiB |
| GET | `/media/{id}/content` | supports single `Range: bytes=a-b` / `a-` / `-n` → 206 + `Content-Range`; 416 on invalid ranges |

## Albums
| Method | Path | Notes |
|---|---|---|
| GET | `/albums` | `{albums:[{id,name,item_count,total_bytes,cover_media_id,...}], smart:{favorites,videos,screenshots,recently_added}, recently_added_since}` |
| POST | `/albums` | `{name, media_ids?}` → 201 album |
| PATCH | `/albums/{id}` | `{name}` |
| DELETE | `/albums/{id}` | media stays in the vault |
| POST | `/albums/{id}/items` | `{media_ids}` |
| POST | `/albums/{id}/items/remove` | `{media_ids}` — never deletes media |

## Limits
JSON ≤ 1 MiB · chunk ≤ 8 MiB (configurable) · thumbnail ≤ 2 MiB · file ≤ 20 GiB · 64 active uploads per device · rate limits on pairing, polling, approval and refresh.
