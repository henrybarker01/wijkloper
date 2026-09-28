"""Endpoints that need no token: health (used for discovery) and pairing."""
from __future__ import annotations

import secrets
import sqlite3
import time

from fastapi import APIRouter, Depends, HTTPException, Request, status

from ..db import APP_VERSION, get_db, get_setting, now_iso, token_hash
from ..ratelimit import FAIL_DELAY, client_ip, pair_limiter
from ..schemas import PairRequest

router = APIRouter(prefix="/api", tags=["public"])


@router.get("/health")
def health(db: sqlite3.Connection = Depends(get_db)):
    from ..importer import import_status

    status = import_status(db)
    attempt, applied = status["last_attempt"], status["last_applied"]
    return {
        "app": "wijkloper",
        "version": APP_VERSION,
        "family_name": get_setting(db, "family_name", "") or "",
        "server_time": now_iso(),
        # Quick check that the nightly import is alive: last successful run,
        # and whether the most recent attempt went through.
        "last_import_at": applied["ran_at"] if applied else None,
        "last_import_attempt_ok": attempt["ok"] if attempt else None,
    }


@router.post("/pair")
def pair(body: PairRequest, request: Request, db: sqlite3.Connection = Depends(get_db)):
    ip = client_ip(request)
    pair_limiter.check(ip)
    expected = get_setting(db, "pairing_code", "") or ""
    if not expected or not secrets.compare_digest(body.pairing_code.strip(), expected):
        pair_limiter.failure(ip)
        time.sleep(FAIL_DELAY)  # make guessing slow even before the lockout kicks in
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Wrong pairing code")
    pair_limiter.success(ip)
    token = secrets.token_urlsafe(32)
    name = (body.device_name or "").strip()[:60] or "Phone"
    cur = db.execute(
        "INSERT INTO devices(name, token_hash, created_at, last_seen_at) VALUES (?,?,?,?)",
        (name, token_hash(token), now_iso(), now_iso()),
    )
    db.commit()
    return {
        "device_id": cur.lastrowid,
        "device_token": token,
        "family_name": get_setting(db, "family_name", "") or "",
    }
