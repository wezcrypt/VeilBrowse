"""WezCrypt Secure Studio — encrypted backup server (stores client-side encrypted data only)."""

from .app_factory import Context, create_app
from .config import Settings

__all__ = ["Context", "Settings", "create_app"]
__version__ = "2.0.0"
