"""SQLite access, schema, seeding and small helpers.

One connection per request (see ``get_db``); SQLite in WAL mode handles the
tiny amount of concurrency a family produces without any extra machinery.
"""
from __future__ import annotations

import datetime as dt
import hashlib
import os
import secrets
import sqlite3
from typing import Iterator, List, Optional

APP_VERSION = "0.1.0"


def data_dir() -> str:
    """Directory that holds the database. Overridable for tests and installs."""
    configured = os.environ.get("WIJKLOPER_DATA_DIR")
    if configured:
        return configured
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(here, "data")


def db_path() -> str:
    return os.path.join(data_dir(), "wijkloper.db")


SCHEMA = """
CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS devices (
    id           INTEGER PRIMARY KEY,
    name         TEXT NOT NULL,
    token_hash   TEXT NOT NULL UNIQUE,
    created_at   TEXT NOT NULL,
    last_seen_at TEXT
);
CREATE TABLE IF NOT EXISTS parent_sessions (
    token_hash TEXT PRIMARY KEY,
    device_id  INTEGER,
    expires_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS kids (
    id               INTEGER PRIMARY KEY,
    name             TEXT NOT NULL,
    emoji            TEXT NOT NULL DEFAULT '',
    color            TEXT NOT NULL DEFAULT '#4F46E5',
    default_route_id INTEGER,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    archived         INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS routes (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    archived   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS products (
    id         INTEGER PRIMARY KEY,
    name       TEXT NOT NULL,
    short_code TEXT NOT NULL,
    color      TEXT NOT NULL,
    days       TEXT NOT NULL,                 -- ISO weekdays as CSV, 1=Mon .. 7=Sun
    kind       TEXT NOT NULL DEFAULT 'paper', -- 'paper' or 'insert'
    sort_order INTEGER NOT NULL DEFAULT 0,
    archived   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS streets (
    id           INTEGER PRIMARY KEY,
    route_id     INTEGER NOT NULL REFERENCES routes(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    number_order TEXT NOT NULL DEFAULT 'asc',
    sort_order   INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS addresses (
    id         INTEGER PRIMARY KEY,
    street_id  INTEGER NOT NULL REFERENCES streets(id) ON DELETE CASCADE,
    number     INTEGER NOT NULL,
    suffix     TEXT NOT NULL DEFAULT '',
    note       TEXT NOT NULL DEFAULT '',
    sort_order INTEGER NOT NULL DEFAULT 0,
    UNIQUE(street_id, number, suffix)
);
CREATE TABLE IF NOT EXISTS address_products (
    address_id INTEGER NOT NULL REFERENCES addresses(id) ON DELETE CASCADE,
    product_id INTEGER NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    days       TEXT,                          -- NULL = use the product's days
    PRIMARY KEY (address_id, product_id)
);
CREATE TABLE IF NOT EXISTS runs (
    id               INTEGER PRIMARY KEY,
    client_run_id    TEXT NOT NULL UNIQUE,
    kid_id           INTEGER REFERENCES kids(id) ON DELETE SET NULL,
    route_id         INTEGER REFERENCES routes(id) ON DELETE SET NULL,
    device_id        INTEGER,
    date             TEXT NOT NULL,           -- local date YYYY-MM-DD
    weekday          INTEGER NOT NULL,        -- ISO 1..7
    started_at       TEXT NOT NULL,
    finished_at      TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    stops_total      INTEGER NOT NULL,
    stops_done       INTEGER NOT NULL,
    papers_json      TEXT NOT NULL DEFAULT '{}',
    events_json      TEXT NOT NULL DEFAULT '[]',
    created_at       TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_runs_kid_date ON runs(kid_id, date);
CREATE INDEX IF NOT EXISTS idx_addresses_street ON addresses(street_id);
"""

NUMBER_ORDERS = (
    "asc",
    "desc",
    "odd_up_even_back",
    "even_up_odd_back",
    "odd_then_even",
    "even_then_odd",
    "custom",
)

DEFAULT_PRODUCTS = [
    # name, short code, color, days, kind
    ("Barnevelder", "B", "#1D4ED8", "1,2,3,4,5,6", "paper"),
    ("Folders", "F", "#F59E0B", "4", "insert"),
    ("De Week", "W", "#16A34A", "4", "paper"),
]


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).astimezone().isoformat(timespec="seconds")


def app_timezone() -> dt.tzinfo:
    """Family's time zone (WIJKLOPER_TZ); servers often run in UTC."""
    name = os.environ.get("WIJKLOPER_TZ", "Europe/Amsterdam")
    try:
        from zoneinfo import ZoneInfo

        return ZoneInfo(name)
    except Exception:  # unknown zone name or no zone data available
        return dt.timezone.utc


def today_local() -> dt.date:
    """Today's date where the kids live, not where the server runs."""
    return dt.datetime.now(app_timezone()).date()


def connect() -> sqlite3.Connection:
    os.makedirs(data_dir(), exist_ok=True)
    conn = sqlite3.connect(db_path(), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def get_db() -> Iterator[sqlite3.Connection]:
    """FastAPI dependency: a connection for the duration of one request."""
    conn = connect()
    try:
        yield conn
    finally:
        conn.close()


# --- settings ---------------------------------------------------------------

def get_setting(db: sqlite3.Connection, key: str, default: Optional[str] = None) -> Optional[str]:
    row = db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row else default


def set_setting(db: sqlite3.Connection, key: str, value: str) -> None:
    db.execute(
        "INSERT INTO settings(key, value) VALUES (?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (key, value),
    )


def bump_config_version(db: sqlite3.Connection) -> int:
    version = int(get_setting(db, "config_version", "0") or 0) + 1
    set_setting(db, "config_version", str(version))
    return version


# --- secrets ----------------------------------------------------------------

def hash_secret(secret: str) -> str:
    """Slow hash for PINs (pbkdf2, stdlib only)."""
    salt = secrets.token_hex(16)
    iterations = 120_000
    digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), iterations)
    return "pbkdf2$%d$%s$%s" % (iterations, salt, digest.hex())


def verify_secret(secret: str, stored: Optional[str]) -> bool:
    if not stored:
        return False
    try:
        _, iterations, salt, expected = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", secret.encode(), bytes.fromhex(salt), int(iterations))
        return secrets.compare_digest(digest.hex(), expected)
    except (ValueError, TypeError):
        return False


def token_hash(token: str) -> str:
    """Fast hash for random high-entropy tokens."""
    return hashlib.sha256(token.encode()).hexdigest()


# --- weekday CSV helpers ------------------------------------------------------

def days_to_list(csv: Optional[str]) -> Optional[List[int]]:
    if csv is None:
        return None
    return sorted({int(p) for p in csv.split(",") if p.strip()})


def days_from_list(days: Optional[List[int]]) -> Optional[str]:
    if days is None:
        return None
    clean = sorted({int(d) for d in days if 1 <= int(d) <= 7})
    return ",".join(str(d) for d in clean)


# --- init -------------------------------------------------------------------

def init_db() -> None:
    """Create tables, default settings and seed data on first start."""
    db = connect()
    try:
        db.executescript(SCHEMA)
        if get_setting(db, "config_version") is None:
            set_setting(db, "config_version", "1")
        if get_setting(db, "family_name") is None:
            set_setting(db, "family_name", os.environ.get("WIJKLOPER_FAMILY_NAME", "Our family"))
        if get_setting(db, "pairing_code") is None:
            code = os.environ.get("WIJKLOPER_PAIRING_CODE") or str(secrets.randbelow(900000) + 100000)
            set_setting(db, "pairing_code", code)
        if get_setting(db, "parent_pin_hash") is None:
            pin = os.environ.get("WIJKLOPER_PARENT_PIN", "1234")
            set_setting(db, "parent_pin_hash", hash_secret(pin))
        if db.execute("SELECT COUNT(*) AS n FROM products").fetchone()["n"] == 0:
            for order, (name, code, color, days, kind) in enumerate(DEFAULT_PRODUCTS):
                db.execute(
                    "INSERT INTO products(name, short_code, color, days, kind, sort_order) VALUES (?,?,?,?,?,?)",
                    (name, code, color, days, kind, order),
                )
        if db.execute("SELECT COUNT(*) AS n FROM routes").fetchone()["n"] == 0:
            db.execute("INSERT INTO routes(name, sort_order) VALUES (?, 0)", ("Route 1",))
        db.commit()
    finally:
        db.close()
