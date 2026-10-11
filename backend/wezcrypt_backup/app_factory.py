"""Application wiring."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from fastapi import FastAPI

from .api import create_router
from .auth import AuthService
from .config import Settings
from .db import Database
from .errors import install_error_handlers
from .service import SERVER_VERSION, BackupService

logger = logging.getLogger("wezcrypt_backup")


@dataclass
class Context:
    settings: Settings
    db: Database
    auth: AuthService
    service: BackupService

    @classmethod
    def build(cls, settings: Settings) -> "Context":
        settings.validate()
        settings.ensure_directories()
        db = Database(settings.db_path)
        applied = db.migrate()
        if applied:
            logger.info("applied migrations: %s", ", ".join(applied))
        return cls(settings, db, AuthService(db, settings), BackupService(db, settings))


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    app = FastAPI(
        title="WezCrypt Encrypted Backup API",
        version=SERVER_VERSION,
        docs_url="/api/v2/docs" if settings.enable_docs else None,
        redoc_url=None,
        openapi_url="/api/v2/openapi.json" if settings.enable_docs else None,
    )
    context = Context.build(settings)
    app.state.ctx = context
    app.include_router(create_router(settings, context.auth, context.service))
    install_error_handlers(app)

    @app.middleware("http")
    async def security_headers(request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    return app
