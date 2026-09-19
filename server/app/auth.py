"""Device pairing tokens and parent sessions."""
from __future__ import annotations

import datetime as dt
import sqlite3
from typing import Optional

from fastapi import Depends, Header, HTTPException, status

from .db import get_db, token_hash

PARENT_SESSION_HOURS = 12


def _now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc).astimezone()


def require_device(
    authorization: Optional[str] = Header(default=None),
    db: sqlite3.Connection = Depends(get_db),
) -> sqlite3.Row:
    """Validate ``Authorization: Bearer <device token>``."""
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Device token missing")
    token = authorization.split(" ", 1)[1].strip()
    device = db.execute("SELECT * FROM devices WHERE token_hash=?", (token_hash(token),)).fetchone()
    if device is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Unknown device, pair again")

    # Throttle last_seen writes to once a minute.
    now = _now()
    stale = True
    if device["last_seen_at"]:
        try:
            stale = (now - dt.datetime.fromisoformat(device["last_seen_at"])).total_seconds() > 60
        except ValueError:
            stale = True
    if stale:
        db.execute(
            "UPDATE devices SET last_seen_at=? WHERE id=?",
            (now.isoformat(timespec="seconds"), device["id"]),
        )
        db.commit()
    return device


def require_parent(
    x_parent_token: Optional[str] = Header(default=None),
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
) -> sqlite3.Row:
    """Validate ``X-Parent-Token`` obtained from ``POST /api/parent/login``."""
    if not x_parent_token:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Parent PIN required")
    now = _now().isoformat(timespec="seconds")
    db.execute("DELETE FROM parent_sessions WHERE expires_at < ?", (now,))
    session = db.execute(
        "SELECT * FROM parent_sessions WHERE token_hash=? AND expires_at >= ?",
        (token_hash(x_parent_token), now),
    ).fetchone()
    db.commit()
    if session is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Parent session expired, enter PIN again")
    return device
