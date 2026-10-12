"""Uniform error envelope: {"error": {"code": "...", "message": "..."}}."""

from __future__ import annotations

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


class APIError(Exception):
    def __init__(self, status: int, code: str, message: str, headers: dict[str, str] | None = None, extra: dict | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.headers = headers or {}
        self.extra = extra or {}


def bad_request(code: str, message: str) -> APIError:
    return APIError(400, code, message)


def unauthorized(code: str = "unauthorized", message: str = "Authentication required") -> APIError:
    return APIError(401, code, message, headers={"WWW-Authenticate": "Bearer"})


def forbidden(code: str, message: str) -> APIError:
    return APIError(403, code, message)


def not_found(code: str = "not_found", message: str = "Not found") -> APIError:
    return APIError(404, code, message)


def conflict(code: str, message: str, extra: dict | None = None) -> APIError:
    return APIError(409, code, message, extra=extra)


def too_large(message: str) -> APIError:
    return APIError(413, "payload_too_large", message)


def rate_limited(retry_after: int) -> APIError:
    return APIError(429, "rate_limited", "Too many requests", headers={"Retry-After": str(retry_after)})


def server_busy(code: str, message: str, retry_after: int, status: int = 429) -> APIError:
    """Back-pressure response. Clients must wait Retry-After seconds before trying again."""
    return APIError(status, code, message, headers={"Retry-After": str(max(1, int(retry_after)))}, extra={"retry_after": max(1, int(retry_after))})


async def _handle(_: Request, exc: Exception) -> JSONResponse:
    assert isinstance(exc, APIError)
    body = {"error": {"code": exc.code, "message": exc.message, **exc.extra}}
    headers = {"Cache-Control": "no-store", **exc.headers}
    return JSONResponse(status_code=exc.status, content=body, headers=headers)


def install_error_handlers(app: FastAPI) -> None:
    app.add_exception_handler(APIError, _handle)
