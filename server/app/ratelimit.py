"""Per-IP lockout for the two endpoints that accept a guessable secret.

The pairing code and the parent PIN are short by design (kids type them), so on
a public server we must make guessing slow: after ``max_failures`` wrong
attempts from one address within ``window_seconds`` the endpoint answers 429
until the window has passed. State lives in memory, which is fine for a single
uvicorn worker (a restart simply forgets the counters).
"""
from __future__ import annotations

import os
import threading
import time
from collections import deque
from typing import Deque, Dict

from fastapi import HTTPException, Request, status

# Seconds to sleep after a wrong secret; tests set it to 0.
FAIL_DELAY = float(os.environ.get("WIJKLOPER_FAIL_DELAY", "1.0"))


class FailureLimiter:
    def __init__(self, max_failures: int = 5, window_seconds: int = 15 * 60) -> None:
        self.max_failures = max_failures
        self.window = window_seconds
        self._failures: Dict[str, Deque[float]] = {}
        self._lock = threading.Lock()

    def _recent(self, key: str, now: float) -> Deque[float]:
        queue = self._failures.setdefault(key, deque())
        while queue and now - queue[0] > self.window:
            queue.popleft()
        return queue

    def check(self, key: str) -> None:
        """Raise 429 when this key has used up its attempts."""
        with self._lock:
            now = time.monotonic()
            queue = self._recent(key, now)
            if len(queue) >= self.max_failures:
                wait_seconds = int(self.window - (now - queue[0])) + 1
                minutes = max(1, -(-wait_seconds // 60))
                raise HTTPException(
                    status.HTTP_429_TOO_MANY_REQUESTS,
                    "Too many attempts. Try again in %d minute%s." % (minutes, "" if minutes == 1 else "s"),
                )

    def failure(self, key: str) -> None:
        with self._lock:
            now = time.monotonic()
            self._recent(key, now).append(now)
            if len(self._failures) > 10_000:  # never let a flood grow memory unbounded
                self._failures.clear()

    def success(self, key: str) -> None:
        with self._lock:
            self._failures.pop(key, None)

    def reset_all(self) -> None:
        with self._lock:
            self._failures.clear()


pair_limiter = FailureLimiter()
pin_limiter = FailureLimiter()


def client_ip(request: Request) -> str:
    """Real client address (uvicorn fills this from X-Forwarded-For when run with --proxy-headers)."""
    return request.client.host if request.client else "unknown"
