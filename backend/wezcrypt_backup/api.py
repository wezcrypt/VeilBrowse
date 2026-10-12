"""HTTP API v2 for the iPhone app: /api/v2/*."""

import hashlib
import ipaddress
import os
import re
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from fastapi.responses import StreamingResponse
from fastapi.routing import APIRoute
from pydantic import BaseModel, ConfigDict, Field
from starlette.concurrency import run_in_threadpool

from .auth import AuthService, Principal
from .config import Settings
from .errors import APIError, bad_request, server_busy, too_large, unauthorized
from .service import HEX64, BackupService

_RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")
NO_STORE = {"Cache-Control": "no-store"}


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class LoginBody(Strict):
    username: str = Field(min_length=2, max_length=32)
    password: str = Field(min_length=1, max_length=1024)
    device_label: str = Field(default="iPhone", max_length=64)


class VaultBody(Strict):
    fingerprint: str = Field(min_length=64, max_length=64)
    format: str = Field(default="WZCE-1", max_length=32)


class CreateUploadBody(Strict):
    object_id: str = Field(min_length=32, max_length=32)
    collection: str = Field(min_length=1, max_length=64)
    size_bytes: int
    chunk_size: int
    chunk_count: int
    sha256: str = Field(min_length=64, max_length=64)


class CreateItemBody(Strict):
    item_id: str = Field(min_length=32, max_length=32)
    collection: str = Field(min_length=1, max_length=64)
    content_tag: str = Field(min_length=64, max_length=64)
    kind: Literal["photo", "video", "livePhoto", "file"]
    manifest: str = Field(min_length=4, max_length=400_000)
    object_ids: list[Annotated[str, Field(min_length=32, max_length=32)]] = Field(min_length=1, max_length=64)


class CheckTagsBody(Strict):
    content_tags: list[Annotated[str, Field(min_length=64, max_length=64)]] = Field(max_length=2000)


def streams_body(endpoint):
    endpoint._wzc_streams_body = True
    return endpoint


def make_limited_route(limit_bytes: int) -> type[APIRoute]:
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


def client_ip(request: Request, settings: Settings) -> str | None:
    host = request.client.host if request.client else None
    if settings.trust_proxy_headers and host:
        try:
            if ipaddress.ip_address(host).is_loopback:
                forwarded = request.headers.get("x-real-ip")
                if forwarded:
                    return forwarded
        except ValueError:
            pass
    return host


def parse_range(header: str | None, size: int) -> tuple[int, int] | None:
    if header is None:
        return None
    invalid = APIError(416, "range_not_satisfiable", "Invalid range", headers={"Content-Range": f"bytes */{size}"})
    match = _RANGE_RE.match(header.strip())
    if not match or size == 0:
        raise invalid
    start_text, end_text = match.groups()
    if not start_text and not end_text:
        raise invalid
    if not start_text:
        length = int(end_text)
        if length == 0:
            raise invalid
        return max(size - length, 0), size - 1
    start = int(start_text)
    end = min(int(end_text), size - 1) if end_text else size - 1
    if start >= size or start > end:
        raise invalid
    return start, end


def _flush_and_sync(handle) -> None:
    handle.flush()
    os.fsync(handle.fileno())


def create_router(settings: Settings, auth: AuthService, service: BackupService) -> APIRouter:
    router = APIRouter(prefix="/api/v2", route_class=make_limited_route(settings.json_body_max_bytes))

    async def principal(authorization: Annotated[str | None, Header()] = None) -> Principal:
        if not authorization or not authorization.startswith("Bearer "):
            raise unauthorized()
        return await run_in_threadpool(auth.authenticate, authorization[7:].strip())

    AuthDep = Annotated[Principal, Depends(principal)]

    @router.get("/health")
    async def health() -> dict:
        return {"status": "ok", "api_version": 2, "encryption": "client-side only"}

    @router.get("/capabilities")
    async def capabilities() -> dict:
        return {
            "api_version": 2,
            "encryption": "client-side only",
            "container_formats": ["WZCE/1"],
            "auth": ["password", "api_key"],
            "resumable_uploads": True,
            "max_chunk_bytes": settings.max_chunk_size,
            "max_object_bytes": settings.max_object_size,
            "max_chunks_per_object": settings.max_chunks_per_object,
            "max_open_upload_sessions": settings.max_active_uploads_per_user,
            "max_concurrent_chunk_requests": settings.max_inflight_chunks_per_user,
            "backpressure": "429/503 with Retry-After",
            "upload_ttl_seconds": settings.upload_ttl,
            "range_downloads": True,
            "integrity": "sha256-per-chunk-and-object",
            "transports": ["https"],
        }

    @router.get("/stats")
    async def stats(p: AuthDep, response: Response) -> dict:
        response.headers.update(NO_STORE)
        return await run_in_threadpool(service.stats, p)

    # ------------------------------------------------------------------ auth

    @router.post("/auth/login")
    async def login(body: LoginBody, request: Request, response: Response) -> dict:
        response.headers.update(NO_STORE)
        return await run_in_threadpool(auth.login, body.username, body.password, client_ip(request, settings), body.device_label)

    @router.post("/auth/logout", status_code=204)
    async def logout(p: AuthDep) -> Response:
        await run_in_threadpool(auth.logout, p)
        return Response(status_code=204)

    @router.get("/me")
    async def me(p: AuthDep, response: Response) -> dict:
        response.headers.update(NO_STORE)
        return await run_in_threadpool(service.account, p)

    @router.get("/vault")
    async def vault(p: AuthDep) -> dict:
        return await run_in_threadpool(service.get_vault, p)

    @router.put("/vault")
    async def put_vault(body: VaultBody, p: AuthDep) -> dict:
        return await run_in_threadpool(service.put_vault, p, body.fingerprint.lower(), body.format)

    # --------------------------------------------------------------- uploads

    @router.post("/uploads")
    async def create_upload(body: CreateUploadBody, p: AuthDep) -> dict:
        return await run_in_threadpool(
            lambda: service.create_upload(
                p, object_id=body.object_id, collection=body.collection, size_bytes=body.size_bytes,
                chunk_size=body.chunk_size, chunk_count=body.chunk_count, sha256=body.sha256.lower(),
            )
        )

    @router.get("/uploads/{upload_id}")
    async def upload_status(upload_id: str, p: AuthDep) -> dict:
        return await run_in_threadpool(service.upload_status, p, upload_id)

    @router.put("/uploads/{upload_id}/chunks/{index}")
    @streams_body
    async def put_chunk(
        upload_id: str,
        index: int,
        request: Request,
        p: AuthDep,
        x_chunk_sha256: Annotated[str | None, Header()] = None,
        content_length: Annotated[int | None, Header()] = None,
    ) -> dict:
        if not x_chunk_sha256 or not HEX64.match(x_chunk_sha256.lower()):
            raise bad_request("checksum_required", "X-Chunk-SHA256 header with the chunk's hex SHA-256 is required")
        declared = x_chunk_sha256.lower()
        slot_key = str(p.user_id)
        if not service.chunk_slots.acquire(slot_key):
            service.count("chunks_rejected_busy")
            raise server_busy(
                "too_many_chunk_requests",
                f"At most {settings.max_inflight_chunks_per_user} chunk uploads may run at the same time; slow down",
                retry_after=2,
            )
        try:
            return await _receive_chunk(upload_id, index, request, p, declared, content_length)
        finally:
            service.chunk_slots.release(slot_key)

    async def _receive_chunk(upload_id: str, index: int, request: Request, p: Principal, declared: str, content_length: int | None) -> dict:
        expected, existing = await run_in_threadpool(service.begin_chunk, p, upload_id, index)
        if content_length is not None and content_length != expected:
            raise bad_request("chunk_size_mismatch", f"chunk {index} must be {expected} bytes")
        temp = service.upload_dir(upload_id) / f"{index:07d}.{os.urandom(6).hex()}.part"
        digest = hashlib.sha256()
        received = 0
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            with os.fdopen(fd, "wb", buffering=1024 * 1024) as out:
                async for piece in request.stream():
                    received += len(piece)
                    if received > expected:
                        raise too_large(f"chunk {index} exceeds {expected} bytes")
                    digest.update(piece)
                    out.write(piece)
                # Flushing to disk can take a while for a large chunk; do it off the
                # event loop so other requests are not stalled.
                await run_in_threadpool(_flush_and_sync, out)
            if received != expected:
                raise bad_request("chunk_truncated", f"chunk {index} must be {expected} bytes, received {received}")
            if digest.hexdigest() != declared:
                raise bad_request("checksum_mismatch", "Chunk content does not match X-Chunk-SHA256")
            if existing is not None and existing["sha256"] == declared:
                temp.unlink(missing_ok=True)
                return {"index": index, "sha256": declared, "status": "already_received"}
            return await run_in_threadpool(service.store_chunk, p, upload_id, index, temp, received, declared)
        finally:
            temp.unlink(missing_ok=True)

    @router.post("/uploads/{upload_id}/complete")
    async def complete_upload(upload_id: str, p: AuthDep) -> dict:
        return await run_in_threadpool(service.complete_upload, p, upload_id)

    @router.delete("/uploads/{upload_id}", status_code=204)
    async def cancel_upload(upload_id: str, p: AuthDep) -> Response:
        await run_in_threadpool(service.cancel_upload, p, upload_id)
        return Response(status_code=204)

    # --------------------------------------------------------------- objects

    @router.api_route("/objects/{object_id}", methods=["GET", "HEAD"])
    async def get_object(object_id: str, request: Request, p: AuthDep, range_: Annotated[str | None, Header(alias="range")] = None) -> Response:
        source = await run_in_threadpool(service.object_source, p, object_id)
        headers = {
            "Accept-Ranges": "bytes",
            "Cache-Control": "private, no-store",
            "X-Content-SHA256": source.sha256,
            "X-Content-Type-Options": "nosniff",
        }
        byte_range = parse_range(range_, source.size)
        if byte_range is None:
            start, end, status = 0, source.size - 1, 200
        else:
            (start, end), status = byte_range, 206
            headers["Content-Range"] = f"bytes {start}-{end}/{source.size}"
        headers["Content-Length"] = str(end - start + 1)
        if request.method == "HEAD":
            return Response(status_code=status, headers=headers, media_type="application/octet-stream")
        return StreamingResponse(service.iter_file(source.path, start, end), status_code=status, headers=headers, media_type="application/octet-stream")

    @router.delete("/objects/{object_id}", status_code=204)
    async def delete_object(object_id: str, p: AuthDep) -> Response:
        await run_in_threadpool(service.delete_object, p, object_id)
        return Response(status_code=204)

    # ----------------------------------------------------------------- items

    @router.post("/items")
    async def create_item(body: CreateItemBody, p: AuthDep, response: Response) -> dict:
        status, item = await run_in_threadpool(
            lambda: service.create_item(
                p, item_id=body.item_id, collection=body.collection, content_tag=body.content_tag.lower(),
                kind=body.kind, manifest_b64=body.manifest, object_ids=body.object_ids,
            )
        )
        response.status_code = status
        return item

    @router.post("/items/check")
    async def check_items(body: CheckTagsBody, p: AuthDep) -> dict:
        return {"existing": await run_in_threadpool(service.check_tags, p, [t.lower() for t in body.content_tags])}

    @router.get("/items")
    async def list_items(
        p: AuthDep,
        collection: str | None = Query(default=None, max_length=64),
        kind: str | None = Query(default=None, max_length=16),
        cursor: str | None = Query(default=None, max_length=256),
        limit: int = Query(default=200, ge=1, le=500),
    ) -> dict:
        return await run_in_threadpool(lambda: service.list_items(p, collection=collection, kind=kind, cursor=cursor, limit=limit))

    @router.get("/items/{item_id}")
    async def get_item(item_id: str, p: AuthDep) -> dict:
        return await run_in_threadpool(service.get_item, p, item_id)

    @router.delete("/items/{item_id}")
    async def delete_item(item_id: str, p: AuthDep, x_wzc_confirm_delete: Annotated[str | None, Header()] = None) -> dict:
        if x_wzc_confirm_delete != "yes":
            raise bad_request("confirmation_required", "Send X-WZC-Confirm-Delete: yes to delete a backup permanently")
        return {"deleted_objects": await run_in_threadpool(service.delete_item, p, item_id)}

    return router
