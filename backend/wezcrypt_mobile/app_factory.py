"""Wiring: standalone service or mounting into the existing studio FastAPI app."""

from __future__ import annotations

import logging
from dataclasses import dataclass

from fastapi import FastAPI

from .api import create_router
from .auth_service import AuthService
from .config import MobileSettings
from .db import Database
from .errors import install_error_handlers
from .legacy import LegacyBridge
from .media import MediaService
from .storage import ObjectStore
from .uploads import UploadService

logger = logging.getLogger("wezcrypt_mobile")


@dataclass
class MobileContext:
    settings: MobileSettings
    db: Database
    store: ObjectStore
    legacy: LegacyBridge
    auth: AuthService
    media: MediaService
    uploads: UploadService

    @classmethod
    def build(cls, settings: MobileSettings, migrate: bool = True) -> "MobileContext":
        settings.validate()
        settings.ensure_directories()
        db = Database(settings.db_path)
        if migrate:
            applied = db.migrate()
            if applied:
                logger.info("applied migrations: %s", ", ".join(applied))
        store = ObjectStore(settings)
        legacy = LegacyBridge(settings)
        auth = AuthService(db, settings)
        media = MediaService(db, settings, store, legacy)
        uploads = UploadService(db, settings, store, media, legacy)
        return cls(settings, db, store, legacy, auth, media, uploads)


def install_mobile_api(app: FastAPI, settings: MobileSettings | None = None) -> MobileContext:
    """Adds /api/mobile/* to an existing FastAPI app without touching its routes."""
    context = MobileContext.build(settings or MobileSettings.from_env())
    app.include_router(create_router(context.settings, context.auth, context.media, context.uploads))
    install_error_handlers(app)
    return context


def create_mobile_app(settings: MobileSettings | None = None) -> FastAPI:
    """Standalone service, deployed behind nginx at /api/mobile/."""
    settings = settings or MobileSettings.from_env()
    docs = settings.enable_docs
    app = FastAPI(
        title="WezCrypt Mobile API",
        version="1.0.0",
        docs_url="/api/mobile/docs" if docs else None,
        redoc_url=None,
        openapi_url="/api/mobile/openapi.json" if docs else None,
    )
    context = install_mobile_api(app, settings)
    app.state.mobile = context

    @app.middleware("http")
    async def security_headers(request, call_next):
        response = await call_next(request)
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    return app
