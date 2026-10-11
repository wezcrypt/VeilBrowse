"""WezCrypt Secure Studio — native iOS app API (additive to the Telegram studio)."""

from .app_factory import MobileContext, create_mobile_app, install_mobile_api
from .config import MobileSettings

__all__ = ["MobileContext", "MobileSettings", "create_mobile_app", "install_mobile_api"]
__version__ = "1.0.0"
