"""Endpoints for paired phones: route config, run uploads, stats, parent login."""
from __future__ import annotations

import datetime as dt
import json
import secrets
import sqlite3
import time
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status

from ..auth import PARENT_SESSION_HOURS, require_device
from ..config_builder import build_config
from ..db import get_db, get_setting, now_iso, token_hash, verify_secret
from ..ratelimit import FAIL_DELAY, client_ip, pin_limiter
from ..schemas import ParentLogin, RunUpload
from ..stats import compute_stats, run_to_dict

router = APIRouter(prefix="/api", tags=["device"])


@router.get("/config")
def get_config(
    known_version: Optional[int] = None,
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    """Full configuration, or ``{"unchanged": true}`` when the phone is up to date."""
    version = int(get_setting(db, "config_version", "1") or 1)
    if known_version is not None and known_version == version:
        return {"unchanged": True, "version": version}
    return build_config(db)


@router.post("/runs")
def upload_run(
    body: RunUpload,
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    """Store a finished run. Idempotent on ``client_run_id`` so retries are safe."""
    existing = db.execute("SELECT id FROM runs WHERE client_run_id=?", (body.client_run_id,)).fetchone()
    if existing is not None:
        return {"id": existing["id"], "duplicate": True, "stats": compute_stats(db, body.kid_id)}

    kid_id = body.kid_id
    if kid_id is not None and db.execute("SELECT 1 FROM kids WHERE id=?", (kid_id,)).fetchone() is None:
        kid_id = None
    route_id = body.route_id
    if route_id is not None and db.execute("SELECT 1 FROM routes WHERE id=?", (route_id,)).fetchone() is None:
        route_id = None

    cur = db.execute(
        "INSERT INTO runs(client_run_id, kid_id, route_id, device_id, date, weekday, started_at, "
        "finished_at, duration_seconds, stops_total, stops_done, papers_json, events_json, created_at) "
        "VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            body.client_run_id,
            kid_id,
            route_id,
            device["id"],
            body.date,
            body.weekday,
            body.started_at,
            body.finished_at,
            body.duration_seconds,
            body.stops_total,
            min(body.stops_done, body.stops_total) if body.stops_total else body.stops_done,
            json.dumps({k: v.model_dump() for k, v in body.papers.items()}),
            json.dumps([e.model_dump() for e in body.events]),
            now_iso(),
        ),
    )
    db.commit()
    return {"id": cur.lastrowid, "duplicate": False, "stats": compute_stats(db, kid_id)}


@router.get("/runs")
def list_runs(
    kid_id: Optional[int] = None,
    limit: int = 50,
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    limit = max(1, min(limit, 500))
    if kid_id is None:
        rows = db.execute("SELECT * FROM runs ORDER BY date DESC, started_at DESC LIMIT ?", (limit,))
    else:
        rows = db.execute(
            "SELECT * FROM runs WHERE kid_id=? ORDER BY date DESC, started_at DESC LIMIT ?",
            (kid_id, limit),
        )
    return {"runs": [run_to_dict(r) for r in rows]}


@router.get("/stats")
def stats(
    kid_id: Optional[int] = None,
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    return compute_stats(db, kid_id)


@router.post("/parent/login")
def parent_login(
    body: ParentLogin,
    request: Request,
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    ip = client_ip(request)
    pin_limiter.check(ip)
    if not verify_secret(body.pin.strip(), get_setting(db, "parent_pin_hash")):
        pin_limiter.failure(ip)
        time.sleep(FAIL_DELAY)
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Wrong PIN")
    pin_limiter.success(ip)
    token = secrets.token_urlsafe(32)
    expires = dt.datetime.now(dt.timezone.utc).astimezone() + dt.timedelta(hours=PARENT_SESSION_HOURS)
    expires_iso = expires.isoformat(timespec="seconds")
    db.execute(
        "INSERT INTO parent_sessions(token_hash, device_id, expires_at) VALUES (?,?,?)",
        (token_hash(token), device["id"], expires_iso),
    )
    db.commit()
    return {"parent_token": token, "expires_at": expires_iso}


@router.post("/parent/logout")
def parent_logout(
    x_parent_token: Optional[str] = Header(default=None),
    device: sqlite3.Row = Depends(require_device),
    db: sqlite3.Connection = Depends(get_db),
):
    if x_parent_token:
        db.execute("DELETE FROM parent_sessions WHERE token_hash=?", (token_hash(x_parent_token),))
        db.commit()
    return {"ok": True}
