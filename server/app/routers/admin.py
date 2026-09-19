"""Parent-only endpoints: everything that changes the route configuration.

Every successful change bumps ``config_version`` so phones know to refresh.
"""
from __future__ import annotations

import sqlite3
from typing import Iterable, List, Optional

from fastapi import APIRouter, Depends, HTTPException, status

from ..auth import require_parent
from ..db import (
    bump_config_version,
    days_from_list,
    get_db,
    get_setting,
    hash_secret,
    set_setting,
)
from ..schemas import (
    AddressIn,
    AddressProductIn,
    AddressUpdate,
    AssignmentUpdate,
    BulkAddresses,
    KidIn,
    OrderIn,
    ProductIn,
    RouteIn,
    SettingsIn,
    StreetIn,
    StreetUpdate,
)

router = APIRouter(prefix="/api/admin", tags=["admin"], dependencies=[Depends(require_parent)])


# --- helpers ------------------------------------------------------------------

def _get_or_404(db: sqlite3.Connection, table: str, row_id: int) -> sqlite3.Row:
    row = db.execute("SELECT * FROM %s WHERE id=?" % table, (row_id,)).fetchone()
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "%s %d not found" % (table[:-1], row_id))
    return row


def _next_order(db: sqlite3.Connection, table: str, where: str = "", params: Iterable = ()) -> int:
    sql = "SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM %s %s" % (table, where)
    return int(db.execute(sql, tuple(params)).fetchone()["n"])


def _done(db: sqlite3.Connection, **extra):
    version = bump_config_version(db)
    db.commit()
    result = {"ok": True, "version": version}
    result.update(extra)
    return result


def _apply_order(db: sqlite3.Connection, table: str, ids: List[int]) -> None:
    for position, row_id in enumerate(ids):
        db.execute("UPDATE %s SET sort_order=? WHERE id=?" % table, (position, row_id))


def _replace_assignments(db: sqlite3.Connection, address_id: int, products: List[AddressProductIn]) -> None:
    db.execute("DELETE FROM address_products WHERE address_id=?", (address_id,))
    for ap in products:
        _get_or_404(db, "products", ap.product_id)
        db.execute(
            "INSERT INTO address_products(address_id, product_id, days) VALUES (?,?,?)",
            (address_id, ap.product_id, days_from_list(ap.days)),
        )


# --- settings & devices -------------------------------------------------------

@router.get("/settings")
def get_settings(db: sqlite3.Connection = Depends(get_db)):
    return {
        "family_name": get_setting(db, "family_name", "") or "",
        "pairing_code": get_setting(db, "pairing_code", "") or "",
        "config_version": int(get_setting(db, "config_version", "1") or 1),
    }


@router.put("/settings")
def update_settings(body: SettingsIn, db: sqlite3.Connection = Depends(get_db)):
    changed_config = False
    if body.family_name is not None:
        set_setting(db, "family_name", body.family_name.strip())
        changed_config = True
    if body.new_pin is not None:
        set_setting(db, "parent_pin_hash", hash_secret(body.new_pin.strip()))
    if body.pairing_code is not None:
        set_setting(db, "pairing_code", body.pairing_code.strip())
    if changed_config:
        return _done(db)
    db.commit()
    return {"ok": True, "version": int(get_setting(db, "config_version", "1") or 1)}


@router.get("/devices")
def list_devices(db: sqlite3.Connection = Depends(get_db)):
    rows = db.execute("SELECT id, name, created_at, last_seen_at FROM devices ORDER BY id")
    return {"devices": [dict(r) for r in rows]}


@router.delete("/devices/{device_id}")
def delete_device(device_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "devices", device_id)
    db.execute("DELETE FROM parent_sessions WHERE device_id=?", (device_id,))
    db.execute("DELETE FROM devices WHERE id=?", (device_id,))
    db.commit()
    return {"ok": True}


# --- kids -----------------------------------------------------------------------

@router.put("/kids/order")
def order_kids(body: OrderIn, db: sqlite3.Connection = Depends(get_db)):
    _apply_order(db, "kids", body.ids)
    return _done(db)


@router.post("/kids")
def create_kid(body: KidIn, db: sqlite3.Connection = Depends(get_db)):
    cur = db.execute(
        "INSERT INTO kids(name, emoji, color, default_route_id, sort_order) VALUES (?,?,?,?,?)",
        (body.name.strip(), body.emoji, body.color, body.default_route_id, _next_order(db, "kids")),
    )
    return _done(db, id=cur.lastrowid)


@router.put("/kids/{kid_id}")
def update_kid(kid_id: int, body: KidIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "kids", kid_id)
    db.execute(
        "UPDATE kids SET name=?, emoji=?, color=?, default_route_id=? WHERE id=?",
        (body.name.strip(), body.emoji, body.color, body.default_route_id, kid_id),
    )
    return _done(db)


@router.delete("/kids/{kid_id}")
def delete_kid(kid_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "kids", kid_id)
    has_runs = db.execute("SELECT 1 FROM runs WHERE kid_id=? LIMIT 1", (kid_id,)).fetchone() is not None
    if has_runs:
        db.execute("UPDATE kids SET archived=1 WHERE id=?", (kid_id,))
    else:
        db.execute("DELETE FROM kids WHERE id=?", (kid_id,))
    return _done(db, archived=has_runs)


# --- products -------------------------------------------------------------------

@router.put("/products/order")
def order_products(body: OrderIn, db: sqlite3.Connection = Depends(get_db)):
    _apply_order(db, "products", body.ids)
    return _done(db)


@router.post("/products")
def create_product(body: ProductIn, db: sqlite3.Connection = Depends(get_db)):
    cur = db.execute(
        "INSERT INTO products(name, short_code, color, days, kind, sort_order) VALUES (?,?,?,?,?,?)",
        (
            body.name.strip(),
            body.short_code.strip().upper(),
            body.color,
            days_from_list(body.days) or "",
            body.kind,
            _next_order(db, "products"),
        ),
    )
    return _done(db, id=cur.lastrowid)


@router.put("/products/{product_id}")
def update_product(product_id: int, body: ProductIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "products", product_id)
    db.execute(
        "UPDATE products SET name=?, short_code=?, color=?, days=?, kind=? WHERE id=?",
        (
            body.name.strip(),
            body.short_code.strip().upper(),
            body.color,
            days_from_list(body.days) or "",
            body.kind,
            product_id,
        ),
    )
    return _done(db)


@router.delete("/products/{product_id}")
def delete_product(product_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "products", product_id)
    db.execute("DELETE FROM products WHERE id=?", (product_id,))  # cascades to assignments
    return _done(db)


# --- routes ---------------------------------------------------------------------

@router.put("/routes/order")
def order_routes(body: OrderIn, db: sqlite3.Connection = Depends(get_db)):
    _apply_order(db, "routes", body.ids)
    return _done(db)


@router.post("/routes")
def create_route(body: RouteIn, db: sqlite3.Connection = Depends(get_db)):
    cur = db.execute(
        "INSERT INTO routes(name, sort_order) VALUES (?,?)",
        (body.name.strip(), _next_order(db, "routes")),
    )
    return _done(db, id=cur.lastrowid)


@router.put("/routes/{route_id}")
def update_route(route_id: int, body: RouteIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "routes", route_id)
    db.execute("UPDATE routes SET name=? WHERE id=?", (body.name.strip(), route_id))
    return _done(db)


@router.delete("/routes/{route_id}")
def delete_route(route_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "routes", route_id)
    has_runs = db.execute("SELECT 1 FROM runs WHERE route_id=? LIMIT 1", (route_id,)).fetchone() is not None
    if has_runs:
        db.execute("UPDATE routes SET archived=1 WHERE id=?", (route_id,))
    else:
        db.execute("DELETE FROM routes WHERE id=?", (route_id,))  # cascades to streets/addresses
    db.execute("UPDATE kids SET default_route_id=NULL WHERE default_route_id=?", (route_id,))
    return _done(db, archived=has_runs)


# --- streets --------------------------------------------------------------------

@router.post("/routes/{route_id}/streets")
def create_street(route_id: int, body: StreetIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "routes", route_id)
    cur = db.execute(
        "INSERT INTO streets(route_id, name, number_order, sort_order) VALUES (?,?,?,?)",
        (
            route_id,
            body.name.strip(),
            body.number_order,
            _next_order(db, "streets", "WHERE route_id=?", (route_id,)),
        ),
    )
    return _done(db, id=cur.lastrowid)


@router.put("/routes/{route_id}/streets/order")
def order_streets(route_id: int, body: OrderIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "routes", route_id)
    for position, street_id in enumerate(body.ids):
        db.execute(
            "UPDATE streets SET sort_order=? WHERE id=? AND route_id=?",
            (position, street_id, route_id),
        )
    return _done(db)


@router.put("/streets/{street_id}")
def update_street(street_id: int, body: StreetUpdate, db: sqlite3.Connection = Depends(get_db)):
    street = _get_or_404(db, "streets", street_id)
    name = body.name.strip() if body.name is not None else street["name"]
    order = body.number_order if body.number_order is not None else street["number_order"]
    db.execute("UPDATE streets SET name=?, number_order=? WHERE id=?", (name, order, street_id))
    return _done(db)


@router.delete("/streets/{street_id}")
def delete_street(street_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "streets", street_id)
    db.execute("DELETE FROM streets WHERE id=?", (street_id,))  # cascades to addresses
    return _done(db)


# --- addresses ------------------------------------------------------------------

@router.post("/streets/{street_id}/addresses")
def create_address(street_id: int, body: AddressIn, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "streets", street_id)
    suffix = body.suffix.strip()
    exists = db.execute(
        "SELECT 1 FROM addresses WHERE street_id=? AND number=? AND suffix=?",
        (street_id, body.number, suffix),
    ).fetchone()
    if exists:
        raise HTTPException(status.HTTP_409_CONFLICT, "That house number already exists in this street")
    cur = db.execute(
        "INSERT INTO addresses(street_id, number, suffix, note, sort_order) VALUES (?,?,?,?,?)",
        (
            street_id,
            body.number,
            suffix,
            body.note.strip(),
            _next_order(db, "addresses", "WHERE street_id=?", (street_id,)),
        ),
    )
    address_id = cur.lastrowid
    _replace_assignments(db, address_id, body.products)
    return _done(db, id=address_id)


@router.post("/streets/{street_id}/addresses/bulk")
def create_addresses_bulk(street_id: int, body: BulkAddresses, db: sqlite3.Connection = Depends(get_db)):
    """Add a whole range of house numbers at once, skipping ones that already exist."""
    _get_or_404(db, "streets", street_id)
    start, end = sorted((body.start, body.end))
    if end - start > 2000:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Range too large")
    created: List[int] = []
    skipped = 0
    order = _next_order(db, "addresses", "WHERE street_id=?", (street_id,))
    for number in range(start, end + 1):
        if body.parity == "odd" and number % 2 == 0:
            continue
        if body.parity == "even" and number % 2 == 1:
            continue
        exists = db.execute(
            "SELECT 1 FROM addresses WHERE street_id=? AND number=? AND suffix=''",
            (street_id, number),
        ).fetchone()
        if exists:
            skipped += 1
            continue
        cur = db.execute(
            "INSERT INTO addresses(street_id, number, suffix, note, sort_order) VALUES (?,?,'','',?)",
            (street_id, number, order),
        )
        order += 1
        created.append(cur.lastrowid)
        _replace_assignments(db, cur.lastrowid, body.products)
    return _done(db, created=len(created), skipped=skipped, ids=created)


@router.put("/streets/{street_id}/addresses/order")
def order_addresses(street_id: int, body: OrderIn, db: sqlite3.Connection = Depends(get_db)):
    """Manual walking order; switches the street to custom ordering."""
    _get_or_404(db, "streets", street_id)
    for position, address_id in enumerate(body.ids):
        db.execute(
            "UPDATE addresses SET sort_order=? WHERE id=? AND street_id=?",
            (position, address_id, street_id),
        )
    db.execute("UPDATE streets SET number_order='custom' WHERE id=?", (street_id,))
    return _done(db)


@router.put("/addresses/{address_id}")
def update_address(address_id: int, body: AddressUpdate, db: sqlite3.Connection = Depends(get_db)):
    address = _get_or_404(db, "addresses", address_id)
    number = body.number if body.number is not None else address["number"]
    suffix = body.suffix.strip() if body.suffix is not None else address["suffix"]
    note = body.note.strip() if body.note is not None else address["note"]
    clash = db.execute(
        "SELECT 1 FROM addresses WHERE street_id=? AND number=? AND suffix=? AND id<>?",
        (address["street_id"], number, suffix, address_id),
    ).fetchone()
    if clash:
        raise HTTPException(status.HTTP_409_CONFLICT, "That house number already exists in this street")
    db.execute(
        "UPDATE addresses SET number=?, suffix=?, note=? WHERE id=?",
        (number, suffix, note, address_id),
    )
    if body.products is not None:
        _replace_assignments(db, address_id, body.products)
    return _done(db)


@router.delete("/addresses/{address_id}")
def delete_address(address_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "addresses", address_id)
    db.execute("DELETE FROM addresses WHERE id=?", (address_id,))
    return _done(db)


@router.put("/assignments")
def update_assignments(body: AssignmentUpdate, db: sqlite3.Connection = Depends(get_db)):
    """Give (or take away) one product for many addresses at once ("paint mode")."""
    _get_or_404(db, "products", body.product_id)
    days = days_from_list(body.days)
    for address_id in body.address_ids:
        if body.assigned:
            db.execute(
                "INSERT INTO address_products(address_id, product_id, days) VALUES (?,?,?) "
                "ON CONFLICT(address_id, product_id) DO UPDATE SET days=excluded.days",
                (address_id, body.product_id, days),
            )
        else:
            db.execute(
                "DELETE FROM address_products WHERE address_id=? AND product_id=?",
                (address_id, body.product_id),
            )
    return _done(db)


# --- runs -----------------------------------------------------------------------

@router.delete("/runs/{run_id}")
def delete_run(run_id: int, db: sqlite3.Connection = Depends(get_db)):
    _get_or_404(db, "runs", run_id)
    db.execute("DELETE FROM runs WHERE id=?", (run_id,))
    db.commit()
    return {"ok": True}
