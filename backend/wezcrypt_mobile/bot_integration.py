"""Helpers for the existing Telegram bot to approve native-app pairings.

The bot already receives authenticated Telegram user ids from Telegram's
servers, so it is the trusted party that binds a device to an account. Use one
of the two approaches below from the bot's message handler:

* :func:`approve_via_http` — call the mobile service over loopback with the
  internal secret (bot and mobile API are separate processes).
* :func:`approve_in_process` — call the service layer directly when the bot
  runs inside the same Python process.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

_PAIR_RE = re.compile(r"^/(?:pair)(?:@\w+)?\s+([A-Za-z0-9-]{8,16})\s*$")
_START_RE = re.compile(r"^/start(?:@\w+)?\s+pair_([A-Za-z0-9]{8})\s*$")


@dataclass(frozen=True)
class ApprovalResult:
    ok: bool
    message: str
    device_name: str | None = None
    device_model: str | None = None


def parse_pair_command(text: str | None) -> str | None:
    """Extracts the code from `/pair ABCD-EFGH` or `/start pair_ABCDEFGH`."""
    if not text:
        return None
    text = text.strip()
    for pattern in (_PAIR_RE, _START_RE):
        match = pattern.match(text)
        if match:
            return match.group(1)
    return None


def _result_from_payload(status: int, payload: dict) -> ApprovalResult:
    if status == 200:
        return ApprovalResult(
            ok=True,
            message=f"✅ Paired “{payload.get('device_name')}” ({payload.get('device_model')}). "
            "If this was not you, revoke it from Settings → Security → Devices in the app.",
            device_name=payload.get("device_name"),
            device_model=payload.get("device_model"),
        )
    error = payload.get("error", {}) if isinstance(payload, dict) else {}
    code = error.get("code")
    if code == "pairing_not_found":
        return ApprovalResult(False, "❌ This code is unknown or expired. Generate a new code in the app.")
    if code == "not_allowed":
        return ApprovalResult(False, "⛔️ This Telegram account is not allowed to pair devices.")
    if code == "rate_limited":
        return ApprovalResult(False, "⏳ Too many attempts. Try again later.")
    return ApprovalResult(False, "⚠️ Pairing failed. Try again.")


def approve_via_http(
    code: str,
    telegram_user_id: int,
    *,
    secret_file: str | Path,
    base_url: str = "http://127.0.0.1:8090",
    timeout: float = 10.0,
) -> ApprovalResult:
    secret = Path(secret_file).read_text(encoding="utf-8").strip()
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/api/mobile/internal/pair/approve",
        data=json.dumps({"code": code, "telegram_user_id": int(telegram_user_id)}).encode(),
        headers={"Content-Type": "application/json", "X-WZC-Internal-Secret": secret},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 - loopback only
            return _result_from_payload(response.status, json.loads(response.read() or b"{}"))
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read() or b"{}")
        except json.JSONDecodeError:
            payload = {}
        return _result_from_payload(exc.code, payload)
    except (urllib.error.URLError, TimeoutError):
        return ApprovalResult(False, "⚠️ The mobile service is not reachable right now.")


def approve_in_process(context, code: str, telegram_user_id: int) -> ApprovalResult:
    """`context` is the :class:`wezcrypt_mobile.MobileContext` returned by install_mobile_api."""
    from .errors import APIError

    try:
        payload = context.auth.approve_pairing(code, int(telegram_user_id))
        return _result_from_payload(200, payload)
    except APIError as exc:
        return _result_from_payload(exc.status, {"error": {"code": exc.code}})
