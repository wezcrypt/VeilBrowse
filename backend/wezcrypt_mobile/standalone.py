"""ASGI entry point: `uvicorn wezcrypt_mobile.standalone:app --host 127.0.0.1 --port 8090`."""

import logging
import os

from .app_factory import create_mobile_app

logging.basicConfig(
    level=os.environ.get("WZC_MOBILE_LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

app = create_mobile_app()
