"""Assemble the full route configuration that phones cache."""
from __future__ import annotations

import datetime as dt
import sqlite3
from typing import Any, Dict, List

from .db import days_to_list, get_setting, today_local


def extra_to_dict(db: sqlite3.Connection, row: sqlite3.Row) -> Dict[str, Any]:
    address_ids = [
        r["address_id"]
        for r in db.execute(
            "SELECT address_id FROM extra_addresses WHERE extra_id=? ORDER BY address_id", (row["id"],)
        )
    ]
    return {
        "id": row["id"],
        "product_id": row["product_id"],
        "date": row["date"],
        "note": row["note"],
        "address_ids": address_ids,
    }


def list_extras(db: sqlite3.Connection, since: str = None) -> List[Dict[str, Any]]:
    """Extra delivery days (one row per date), optionally only from ``since`` on."""
    if since is None:
        rows = db.execute("SELECT * FROM extras ORDER BY date, id")
    else:
        rows = db.execute("SELECT * FROM extras WHERE date >= ? ORDER BY date, id", (since,))
    return [extra_to_dict(db, r) for r in rows]


def build_config(db: sqlite3.Connection) -> Dict[str, Any]:
    version = int(get_setting(db, "config_version", "1") or 1)

    kids = [
        {
            "id": r["id"],
            "name": r["name"],
            "emoji": r["emoji"],
            "color": r["color"],
            "default_route_id": r["default_route_id"],
            "sort_order": r["sort_order"],
        }
        for r in db.execute("SELECT * FROM kids WHERE archived=0 ORDER BY sort_order, id")
    ]

    routes = [
        {"id": r["id"], "name": r["name"], "sort_order": r["sort_order"]}
        for r in db.execute("SELECT * FROM routes WHERE archived=0 ORDER BY sort_order, id")
    ]

    products = [
        {
            "id": r["id"],
            "name": r["name"],
            "short_code": r["short_code"],
            "color": r["color"],
            "days": days_to_list(r["days"]) or [],
            "kind": r["kind"],
            "sort_order": r["sort_order"],
        }
        for r in db.execute("SELECT * FROM products WHERE archived=0 ORDER BY sort_order, id")
    ]

    streets = [
        {
            "id": r["id"],
            "route_id": r["route_id"],
            "name": r["name"],
            "number_order": r["number_order"],
            "sort_order": r["sort_order"],
        }
        for r in db.execute(
            "SELECT s.* FROM streets s JOIN routes r ON r.id = s.route_id "
            "WHERE r.archived = 0 ORDER BY s.route_id, s.sort_order, s.id"
        )
    ]

    assignments: Dict[int, List[Dict[str, Any]]] = {}
    for r in db.execute(
        "SELECT ap.address_id, ap.product_id, ap.days FROM address_products ap "
        "JOIN products p ON p.id = ap.product_id WHERE p.archived = 0 "
        "ORDER BY p.sort_order, p.id"
    ):
        assignments.setdefault(r["address_id"], []).append(
            {"product_id": r["product_id"], "days": days_to_list(r["days"])}
        )

    addresses = [
        {
            "id": r["id"],
            "street_id": r["street_id"],
            "number": r["number"],
            "suffix": r["suffix"],
            "note": r["note"],
            "sort_order": r["sort_order"],
            "sticker": r["sticker"],
            "products": assignments.get(r["id"], []),
        }
        for r in db.execute(
            "SELECT a.* FROM addresses a JOIN streets s ON s.id = a.street_id "
            "JOIN routes r ON r.id = s.route_id WHERE r.archived = 0 "
            "ORDER BY a.street_id, a.sort_order, a.number, a.suffix"
        )
    ]

    # Phones only need upcoming extras (plus yesterday, for late uploads around midnight).
    since = (today_local() - dt.timedelta(days=1)).isoformat()

    from .importer import import_status, recent_changes

    return {
        "version": version,
        "family_name": get_setting(db, "family_name", "") or "",
        "kids": kids,
        "routes": routes,
        "products": products,
        "streets": streets,
        "addresses": addresses,
        "extras": list_extras(db, since),
        # What changed on the round lately, so the kids notice houses that were
        # added or stopped instead of walking the route from memory.
        "changes": recent_changes(db),
        # When the subscriber list was last pulled from the distributor.
        "import_status": import_status(db),
    }
