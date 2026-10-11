"""ASGI entry point: `uvicorn wezcrypt_backup.standalone:app --host 127.0.0.1 --port 8091 --workers 1`."""

import logging
import os

from .app_factory import create_app

logging.basicConfig(level=os.environ.get("WZC_BACKUP_LOG_LEVEL", "INFO").upper(), format="%(asctime)s %(levelname)s %(name)s: %(message)s")

app = create_app()
