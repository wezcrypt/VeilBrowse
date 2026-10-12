"""In-process sliding-window rate limiter (single uvicorn worker deployment)."""

from __future__ import annotations

import threading
import time
from collections import deque


class ConcurrencyLimiter:
    """Counts requests in progress per key. Always pair acquire() with release()
    (use `slot()`), so a failing request can never leak a slot."""

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self._active: dict[str, int] = {}
        self._lock = threading.Lock()

    def acquire(self, key: str) -> bool:
        with self._lock:
            current = self._active.get(key, 0)
            if current >= self.limit:
                return False
            self._active[key] = current + 1
            return True

    def release(self, key: str) -> None:
        with self._lock:
            current = self._active.get(key, 0) - 1
            if current > 0:
                self._active[key] = current
            else:
                self._active.pop(key, None)

    def active(self, key: str) -> int:
        with self._lock:
            return self._active.get(key, 0)

    def total(self) -> int:
        with self._lock:
            return sum(self._active.values())


class SlidingWindowLimiter:
    def __init__(self, limit: int, window_seconds: int, clock=time.monotonic) -> None:
        self.limit = limit
        self.window = window_seconds
        self._clock = clock
        self._hits: dict[str, deque[float]] = {}
        self._lock = threading.Lock()

    def check(self, key: str) -> int:
        """Records a hit. Returns 0 when allowed, otherwise seconds to wait."""
        now = self._clock()
        with self._lock:
            hits = self._hits.setdefault(key, deque())
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return max(1, int(self.window - (now - hits[0])) + 1)
            hits.append(now)
            if len(self._hits) > 50_000:
                self._evict(now)
            return 0

    def blocked(self, key: str) -> int:
        """Checks without recording. Returns 0 when allowed, otherwise seconds to wait."""
        now = self._clock()
        with self._lock:
            hits = self._hits.get(key)
            if not hits:
                return 0
            while hits and now - hits[0] >= self.window:
                hits.popleft()
            if len(hits) >= self.limit:
                return max(1, int(self.window - (now - hits[0])) + 1)
            return 0

    def record(self, key: str) -> None:
        """Records one hit without checking (e.g. a failed login)."""
        now = self._clock()
        with self._lock:
            self._hits.setdefault(key, deque()).append(now)
            if len(self._hits) > 50_000:
                self._evict(now)

    def reset(self, key: str) -> None:
        with self._lock:
            self._hits.pop(key, None)

    def _evict(self, now: float) -> None:
        stale = [key for key, hits in self._hits.items() if not hits or now - hits[-1] >= self.window]
        for key in stale:
            del self._hits[key]
