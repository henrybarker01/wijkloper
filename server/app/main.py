"""Wijkloper API entry point.

Run locally:   python -m uvicorn app.main:app --host 0.0.0.0 --port 8000
Browse docs:   http://localhost:8000/docs
"""
from __future__ import annotations

import os
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import HTMLResponse

from .db import APP_VERSION, init_db
from .routers import admin, device, public

# Interactive API docs are handy on a home server; on a public one you may
# prefer to hide them (WIJKLOPER_ENABLE_DOCS=0).
ENABLE_DOCS = os.environ.get("WIJKLOPER_ENABLE_DOCS", "1").lower() not in ("0", "false", "no")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    init_db()
    yield


app = FastAPI(
    title="Wijkloper API",
    version=APP_VERSION,
    description="Paper route helper for kids and parents. Phones pair with the family code, "
    "parents unlock editing with their PIN.",
    lifespan=lifespan,
    docs_url="/docs" if ENABLE_DOCS else None,
    redoc_url=None,
    openapi_url="/openapi.json" if ENABLE_DOCS else None,
)
app.include_router(public.router)
app.include_router(device.router)
app.include_router(admin.router)


INDEX_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Wijkloper server</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
 body{font-family:system-ui,sans-serif;max-width:40rem;margin:3rem auto;padding:0 1rem;line-height:1.5;color:#1f2937}
 h1{margin-bottom:.25rem} .ok{color:#16a34a;font-weight:600} code{background:#f3f4f6;padding:.1rem .3rem;border-radius:.25rem}
</style></head><body>
<h1>Wijkloper server</h1>
<p class="ok">Running (version %s).</p>
<p>Open the Wijkloper app, point it at this server and enter the family pairing code.
Parents unlock editing with their PIN.</p>
<p>Health check: <code>/api/health</code>.%s</p>
</body></html>""" % (
    APP_VERSION,
    ' Developers: <a href="/docs">interactive API docs</a>.' if ENABLE_DOCS else "",
)


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def index() -> str:
    return INDEX_HTML
