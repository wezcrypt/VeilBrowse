"""HTTP routes for the native iOS app, mounted under /api/mobile."""


import ipaddress
import logging
import re
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from fastapi.responses import StreamingResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from .auth_service import AuthService, Principal
from .config import MobileSettings
from .errors import APIError, bad_request, forbidden, rate_limited, too_large, unauthorized
from .media import LibraryQuery, MediaService
from .ratelimit import SlidingWindowLimiter
from .security import constant_time_equals
from .uploads import UploadService, parse_checksum

logger = logging.getLogger("wezcrypt_mobile.api")

ID_PATTERN = r"^[0-9a-f]{32}$"
_RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")
NO_STORE = {"Cache-Control": "no-store"}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class PairStartBody(Strict):
    device_name: str = Field(min_length=1, max_length=80)
    device_model: str = Field(min_length=1, max_length=80)
    system_version: str = Field(min_length=1, max_length=40)
    public_key: str = Field(min_length=40, max_length=400)


class PairPollBody(Strict):
    pairing_id: str = Field(pattern=ID_PATTERN)
    poll_secret: str = Field(min_length=10, max_length=128)


class InternalApproveBody(Strict):
    code: str = Field(min_length=8, max_length=16)
    telegram_user_id: int = Field(gt=0)


class RefreshBody(Strict):
    device_id: str = Field(pattern=ID_PATTERN)
    refresh_token: str = Field(min_length=10, max_length=128)
    timestamp: int
    signature: str = Field(min_length=40, max_length=200)


class SyncCheckBody(Strict):
    sha256: list[Annotated[str, Field(pattern=r"^[0-9a-f]{64}$")]] = Field(max_length=2000)


class CreateUploadBody(Strict):
    filename: str = Field(min_length=1, max_length=255)
    mime_type: str = Field(min_length=3, max_length=127)
    media_type: Literal["photo", "video"]
    size_bytes: int = Field(ge=0)
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    taken_at: int | None = Field(default=None, ge=0)
    width: int | None = Field(default=None, ge=0, le=200_000)
    height: int | None = Field(default=None, ge=0, le=200_000)
    duration_ms: int | None = Field(default=None, ge=0)
    is_favorite: bool = False
    is_screenshot: bool = False
    local_identifier: str | None = Field(default=None, max_length=255)


class MediaPatchBody(Strict):
    filename: str | None = Field(default=None, min_length=1, max_length=255)
    is_favorite: bool | None = None


class MediaIdsBody(Strict):
    media_ids: list[Annotated[str, Field(pattern=ID_PATTERN)]] = Field(min_length=1, max_length=1000)


class BulkFavoriteBody(MediaIdsBody):
    is_favorite: bool


class AlbumCreateBody(Strict):
    name: str = Field(min_length=1, max_length=120)
    media_ids: list[Annotated[str, Field(pattern=ID_PATTERN)]] = Field(default_factory=list, max_length=1000)


class AlbumRenameBody(Strict):
    name: str = Field(min_length=1, max_length=120)


def client_ip(request: Request, settings: MobileSettings) -> str | None:
    host = request.client.host if request.client else None
    if settings.trust_proxy_headers and host:
        try:
            if ipaddress.ip_address(host).is_loopback:
                forwarded = request.headers.get("x-real-ip") or request.headers.get("x-forwarded-for", "").split(",")[-1].strip()
                if forwarded:
                    return forwarded
        except ValueError:
            pass
    return host


def parse_range(header: str | None, size: int) -> tuple[int, int] | None:
    if header is None:
        return None
    match = _RANGE_RE.match(header.strip())
    if not match or size == 0:
        raise APIError(416, "range_not_satisfiable", "Invalid range", headers={"Content-Range": f"bytes */{size}"})
    start_text, end_text = match.groups()
    if start_text == "" and end_text == "":
        raise APIError(416, "range_not_satisfiable", "Invalid range", headers={"Content-Range": f"bytes */{size}"})
    if start_text == "":
        length = int(end_text)
        if length == 0:
            raise APIError(416, "range_not_satisfiable", "Invalid range", headers={"Content-Range": f"bytes */{size}"})
        start, end = max(size - length, 0), size - 1
    else:
        start = int(start_text)
        end = int(end_text) if end_text else size - 1
        end = min(end, size - 1)
    if start >= size or start > end:
        raise APIError(416, "range_not_satisfiable", "Invalid range", headers={"Content-Range": f"bytes */{size}"})
    return start, end


def streams_body(endpoint):
    """Marks endpoints that read and cap the raw request stream themselves."""
    endpoint._wzc_streams_body = True
    return endpoint


def make_limited_route(limit_bytes: int) -> type[APIRoute]:
    """Rejects oversized bodies before FastAPI parses JSON."""

    class LimitedRoute(APIRoute):
        def get_route_handler(self):
            original = super().get_route_handler()
            endpoint = self.endpoint

            async def handler(request: Request) -> Response:
                if request.method in {"POST", "PUT", "PATCH", "DELETE"} and not getattr(endpoint, "_wzc_streams_body", False):
                    length = request.headers.get("content-length")
                    if length is not None:
                        if not length.isdigit():
                            raise bad_request("invalid_content_length", "Invalid Content-Length")
                        if int(length) > limit_bytes:
                            raise too_large("Request body too large")
                    else:
                        body = bytearray()
                        async for piece in request.stream():
                            body.extend(piece)
                            if len(body) > limit_bytes:
                                raise too_large("Request body too large")
                        request._body = bytes(body)
                return await original(request)

            return handler

    return LimitedRoute


def create_router(settings: MobileSettings, auth: AuthService, media: MediaService, uploads: UploadService) -> APIRouter:
    router = APIRouter(prefix="/api/mobile", tags=["mobile"], route_class=make_limited_route(settings.json_body_max_bytes))
    pair_limiter = SlidingWindowLimiter(limit=10, window_seconds=600)
    poll_limiter = SlidingWindowLimiter(limit=120, window_seconds=600)
    refresh_limiter = SlidingWindowLimiter(limit=30, window_seconds=600)
    approve_limiter = SlidingWindowLimiter(limit=10, window_seconds=3600)

    def limit(limiter: SlidingWindowLimiter, key: str) -> None:
        wait = limiter.check(key)
        if wait:
            raise rate_limited(wait)

    async def principal(request: Request, authorization: Annotated[str | None, Header()] = None) -> Principal:
        if not authorization or not authorization.startswith("Bearer "):
            raise unauthorized()
        token = authorization[7:].strip()
        return await run_in_threadpool(auth.authenticate, token)

    AuthDep = Annotated[Principal, Depends(principal)]

    # ----------------------------------------------------------------- health

    @router.get("/health")
    async def health() -> dict:
        return {"status": "ok", "api_version": 1}

    # ---------------------------------------------------------------- pairing

    @router.post("/pair/start")
    async def pair_start(body: PairStartBody, request: Request, response: Response) -> dict:
        ip = client_ip(request, settings)
        limit(pair_limiter, f"ip:{ip}")
        response.headers.update(NO_STORE)
        return await run_in_threadpool(
            lambda: auth.start_pairing(
                device_name=body.device_name,
                device_model=body.device_model,
                system_version=body.system_version,
                public_key_b64=body.public_key,
                client_ip=ip,
            )
        )

    @router.post("/pair/poll")
    async def pair_poll(body: PairPollBody, request: Request, response: Response) -> dict:
        limit(poll_limiter, f"pair:{body.pairing_id}")
        response.headers.update(NO_STORE)
        return await run_in_threadpool(auth.poll_pairing, body.pairing_id, body.poll_secret)

    @router.post("/internal/pair/approve", include_in_schema=False)
    async def internal_approve(
        body: InternalApproveBody,
        request: Request,
        x_wzc_internal_secret: Annotated[str | None, Header()] = None,
    ) -> dict:
        host = request.client.host if request.client else ""
        try:
            loopback = ipaddress.ip_address(host).is_loopback
        except ValueError:
            loopback = False
        proxied = "x-forwarded-for" in request.headers or "x-real-ip" in request.headers
        if not settings.internal_secret or not loopback or proxied:
            raise forbidden("forbidden", "Internal endpoint")
        if not x_wzc_internal_secret or not constant_time_equals(x_wzc_internal_secret, settings.internal_secret):
            raise forbidden("forbidden", "Internal endpoint")
        limit(approve_limiter, f"tg:{body.telegram_user_id}")
        return await run_in_threadpool(auth.approve_pairing, body.code, body.telegram_user_id)

    # ---------------------------------------------------------------- session

    @router.post("/session/refresh")
    async def session_refresh(body: RefreshBody, request: Request, response: Response) -> dict:
        ip = client_ip(request, settings)
        limit(refresh_limiter, f"device:{body.device_id}")
        response.headers.update(NO_STORE)
        return await run_in_threadpool(
            lambda: auth.refresh(
                device_id=body.device_id,
                refresh_token=body.refresh_token,
                timestamp=body.timestamp,
                signature_b64=body.signature,
                client_ip=ip,
            )
        )

    @router.post("/session/logout", status_code=204)
    async def session_logout(p: AuthDep, request: Request) -> Response:
        await run_in_threadpool(auth.revoke_device, p, p.device_id, client_ip(request, settings))
        return Response(status_code=204)

    @router.get("/devices")
    async def devices(p: AuthDep) -> dict:
        return {"devices": await run_in_threadpool(auth.list_devices, p)}

    @router.delete("/devices/{device_id}", status_code=204)
    async def revoke_device(device_id: str, p: AuthDep, request: Request) -> Response:
        if not re.match(ID_PATTERN, device_id):
            raise bad_request("invalid_id", "Invalid device id")
        await run_in_threadpool(auth.revoke_device, p, device_id, client_ip(request, settings))
        return Response(status_code=204)

    @router.get("/account")
    async def account(p: AuthDep) -> dict:
        return await run_in_threadpool(media.account, p)

    # ------------------------------------------------------------------- sync

    @router.post("/sync/check")
    async def sync_check(body: SyncCheckBody, p: AuthDep) -> dict:
        return {"existing": await run_in_threadpool(media.check_hashes, p, body.sha256)}

    # ---------------------------------------------------------------- uploads

    @router.post("/uploads")
    async def create_upload(body: CreateUploadBody, p: AuthDep) -> dict:
        return await run_in_threadpool(uploads.create, p, body.model_dump())

    @router.get("/uploads/{upload_id}")
    async def upload_status(upload_id: str, p: AuthDep) -> dict:
        if not re.match(ID_PATTERN, upload_id):
            raise bad_request("invalid_id", "Invalid upload id")
        return await run_in_threadpool(uploads.status, p, upload_id)

    @router.patch("/uploads/{upload_id}")
    @streams_body
    async def upload_chunk(
        upload_id: str,
        request: Request,
        p: AuthDep,
        upload_offset: Annotated[int, Header(ge=0)],
        upload_checksum: Annotated[str | None, Header()] = None,
        content_length: Annotated[int | None, Header()] = None,
    ) -> dict:
        if not re.match(ID_PATTERN, upload_id):
            raise bad_request("invalid_id", "Invalid upload id")
        checksum = parse_checksum(upload_checksum)
        limit_bytes = settings.max_chunk_bytes
        if content_length is not None and content_length > limit_bytes:
            raise too_large("Chunk exceeds the maximum chunk size")
        buffer = bytearray()
        async for piece in request.stream():
            buffer.extend(piece)
            if len(buffer) > limit_bytes:
                raise too_large("Chunk exceeds the maximum chunk size")
        if content_length is not None and content_length != len(buffer):
            raise bad_request("length_mismatch", "Body length does not match Content-Length")
        return await run_in_threadpool(uploads.append, p, upload_id, upload_offset, bytes(buffer), checksum)

    @router.post("/uploads/{upload_id}/complete")
    async def complete_upload(upload_id: str, p: AuthDep) -> dict:
        if not re.match(ID_PATTERN, upload_id):
            raise bad_request("invalid_id", "Invalid upload id")
        return await run_in_threadpool(uploads.complete, p, upload_id)

    @router.delete("/uploads/{upload_id}", status_code=204)
    async def cancel_upload(upload_id: str, p: AuthDep) -> Response:
        if not re.match(ID_PATTERN, upload_id):
            raise bad_request("invalid_id", "Invalid upload id")
        await run_in_threadpool(uploads.cancel, p, upload_id)
        return Response(status_code=204)

    # ---------------------------------------------------------------- library

    @router.get("/library")
    async def library(
        p: AuthDep,
        cursor: str | None = Query(default=None, max_length=512),
        limit_: int = Query(default=200, alias="limit", ge=1, le=500),
        media_type: Literal["photo", "video"] | None = Query(default=None, alias="type"),
        favorite: bool | None = None,
        screenshot: bool | None = None,
        q: str | None = Query(default=None, max_length=200),
        date_from: int | None = Query(default=None, alias="from"),
        date_to: int | None = Query(default=None, alias="to"),
        album_id: str | None = Query(default=None, pattern=ID_PATTERN),
        added_since: int | None = None,
        sort: Literal["taken", "added"] = "taken",
    ) -> dict:
        query = LibraryQuery(
            cursor=cursor, limit=limit_, media_type=media_type, favorite=favorite, screenshot=screenshot, q=q,
            date_from=date_from, date_to=date_to, album_id=album_id, added_since=added_since, sort=sort,
        )
        return await run_in_threadpool(media.list, p, query)

    @router.get("/library/summary")
    async def library_summary(
        p: AuthDep,
        granularity: Literal["day", "month", "year"] = "month",
        tz_offset_minutes: int = Query(default=0, ge=-840, le=840),
        before: str | None = Query(default=None, max_length=10),
        limit_: int = Query(default=500, alias="limit", ge=1, le=1000),
        media_type: Literal["photo", "video"] | None = Query(default=None, alias="type"),
    ) -> dict:
        return await run_in_threadpool(media.summary, p, granularity, tz_offset_minutes, before, limit_, media_type)

    # ------------------------------------------------------------------ media

    def check_id(media_id: str) -> None:
        if not re.match(ID_PATTERN, media_id):
            raise bad_request("invalid_id", "Invalid media id")

    @router.get("/media/{media_id}")
    async def media_get(media_id: str, p: AuthDep) -> dict:
        check_id(media_id)
        return await run_in_threadpool(media.get, p, media_id)

    @router.patch("/media/{media_id}")
    async def media_patch(media_id: str, body: MediaPatchBody, p: AuthDep) -> dict:
        check_id(media_id)
        return await run_in_threadpool(lambda: media.update(p, media_id, filename=body.filename, is_favorite=body.is_favorite))

    @router.post("/media/favorite")
    async def media_favorite_bulk(body: BulkFavoriteBody, p: AuthDep) -> dict:
        return {"updated": await run_in_threadpool(media.set_favorite_bulk, p, body.media_ids, body.is_favorite)}

    @router.post("/media/delete")
    async def media_delete(body: MediaIdsBody, p: AuthDep, x_wzc_confirm_delete: Annotated[str | None, Header()] = None) -> dict:
        if x_wzc_confirm_delete != "yes":
            raise bad_request("confirmation_required", "Send X-WZC-Confirm-Delete: yes to delete media permanently")
        return {"deleted": await run_in_threadpool(media.delete, p, body.media_ids)}

    @router.get("/media/{media_id}/thumbnail")
    async def media_thumbnail(media_id: str, p: AuthDep) -> Response:
        check_id(media_id)
        data, mime = await run_in_threadpool(media.thumbnail, p, media_id)
        return Response(content=data, media_type=mime, headers={"Cache-Control": "private, no-store"})

    @router.put("/media/{media_id}/thumbnail", status_code=204)
    @streams_body
    async def media_put_thumbnail(media_id: str, request: Request, p: AuthDep) -> Response:
        check_id(media_id)
        buffer = bytearray()
        async for piece in request.stream():
            buffer.extend(piece)
            if len(buffer) > settings.thumbnail_max_bytes:
                raise too_large("Thumbnail too large")
        await run_in_threadpool(media.put_thumbnail, p, media_id, bytes(buffer))
        return Response(status_code=204)

    @router.get("/media/{media_id}/content")
    async def media_content(media_id: str, p: AuthDep, range_: Annotated[str | None, Header(alias="range")] = None) -> Response:
        check_id(media_id)
        source = await run_in_threadpool(media.content_source, p, media_id)
        base_headers = {
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, no-store",
            "X-Content-Type-Options": "nosniff",
            "Content-Disposition": "inline",
        }
        byte_range = parse_range(range_, source.size)
        if source.size == 0:
            return Response(content=b"", media_type=source.mime_type, headers=base_headers)
        if byte_range is None:
            start, end, status = 0, source.size - 1, 200
        else:
            (start, end), status = byte_range, 206
            base_headers["Content-Range"] = f"bytes {start}-{end}/{source.size}"
        base_headers["Content-Length"] = str(end - start + 1)
        return StreamingResponse(source.opener(start, end), status_code=status, media_type=source.mime_type, headers=base_headers)

    # ----------------------------------------------------------------- albums

    @router.get("/albums")
    async def albums(p: AuthDep) -> dict:
        return await run_in_threadpool(media.list_albums, p)

    @router.post("/albums", status_code=201)
    async def album_create(body: AlbumCreateBody, p: AuthDep) -> dict:
        return await run_in_threadpool(media.create_album, p, body.name, body.media_ids)

    @router.patch("/albums/{album_id}")
    async def album_rename(album_id: str, body: AlbumRenameBody, p: AuthDep) -> dict:
        check_id(album_id)
        return await run_in_threadpool(media.rename_album, p, album_id, body.name)

    @router.delete("/albums/{album_id}", status_code=204)
    async def album_delete(album_id: str, p: AuthDep) -> Response:
        check_id(album_id)
        await run_in_threadpool(media.delete_album, p, album_id)
        return Response(status_code=204)

    @router.post("/albums/{album_id}/items")
    async def album_add(album_id: str, body: MediaIdsBody, p: AuthDep) -> dict:
        check_id(album_id)
        return await run_in_threadpool(media.add_to_album, p, album_id, body.media_ids)

    @router.post("/albums/{album_id}/items/remove")
    async def album_remove(album_id: str, body: MediaIdsBody, p: AuthDep) -> dict:
        check_id(album_id)
        return await run_in_threadpool(media.remove_from_album, p, album_id, body.media_ids)

    return router
