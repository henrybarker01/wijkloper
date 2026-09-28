"""Apply a delivery list from an outside source (the distributor's portal) to
the Wijkloper route.

The importer takes a *normalised* payload, so the portal-specific parsing lives
in ``app/sources/`` and this module never has to know about it:

    {
      "source": "spread-it",
      "district": "3772-013",
      "fetched_at": "2026-09-21T03:00:00+02:00",
      "route": "Route 1",                     # optional, else the first route
      "covers_products": ["Barneveldse Krant"],
      "streets": [
        {"name": "Nairacstraat",
         "addresses": [{"number": 37, "suffix": "", "products": ["Barneveldse Krant"]}]}
      ]
    }

An entry in ``products`` is either a plain name (the house gets it on the
product's usual weekdays) or ``{"name": ..., "days": [6]}`` for a house that
only gets it on some of them, such as the Saturday-only subscribers.

``covers_products`` is what makes a partial list safe: the importer only ever
adds or removes assignments for the products the payload actually covers, and
only inside the streets it lists. A Monday list that contains no De Week
addresses therefore cannot wipe the De Week round.

Houses that disappear from the source keep their address row (with any note a
parent wrote); only the assignment for the covered product is removed, so the
house simply stops being delivered.
"""
from __future__ import annotations

import datetime as dt
import json
import re
import sqlite3
from typing import Any, Dict, Iterable, List, Optional, Set, Tuple

from .db import bump_config_version, days_from_list, get_setting, now_iso, today_local

# A source list that would strip out more than this share of the covered
# assignments is treated as a broken feed rather than a real change. The guard
# only bites once more than MIN_REMOVALS houses are involved, so ordinary
# churn (a handful of stopped subscribers) always goes through.
DEFAULT_MAX_REMOVE_RATIO = 0.25
DEFAULT_MIN_REMOVALS_BEFORE_GUARD = 8

# settings key holding {"portal product name": "wijkloper product name"}
PRODUCT_MAP_KEY = "import_product_map"

AddressKey = Tuple[int, str]  # (number, suffix)
# product id -> days CSV ("6") or None meaning "the product's usual days"
Assignment = Dict[int, Optional[str]]


class ImportError_(ValueError):
    """Raised when a payload is unusable; the caller reports and changes nothing."""


def normalise_street(name: str) -> str:
    return re.sub(r"\s+", " ", (name or "").strip()).casefold()


def _clean_suffix(value: Any) -> str:
    return str(value or "").strip()


def load_product_map(db: sqlite3.Connection) -> Dict[str, str]:
    raw = get_setting(db, PRODUCT_MAP_KEY, "") or ""
    if not raw.strip():
        return {}
    try:
        value = json.loads(raw)
    except ValueError:
        return {}
    return {str(k): str(v) for k, v in value.items()} if isinstance(value, dict) else {}


def _resolve_products(
    db: sqlite3.Connection, names: Iterable[str], product_map: Dict[str, str]
) -> Dict[str, int]:
    """Portal product name -> Wijkloper product id, via the configured mapping."""
    by_name = {
        str(row["name"]).casefold(): row["id"]
        for row in db.execute("SELECT id, name FROM products WHERE archived=0")
    }
    resolved: Dict[str, int] = {}
    unknown: List[str] = []
    for name in names:
        target = product_map.get(name, name)
        product_id = by_name.get(str(target).casefold())
        if product_id is None:
            unknown.append(f"{name!r}" + ("" if target == name else f" (mapped to {target!r})"))
        else:
            resolved[name] = product_id
    if unknown:
        raise ImportError_(
            "These products from the source do not exist in Wijkloper: "
            + ", ".join(unknown)
            + ". Add them under Parent mode > Papers & folders, or set the "
            + f"{PRODUCT_MAP_KEY} setting to map the names."
        )
    return resolved


def _parse_products(entries: Any, resolved: Dict[str, int], where: str) -> Assignment:
    """[{"name": .., "days": [..]} | "name"] -> {product id: days CSV or None}."""
    out: Assignment = {}
    for entry in entries or []:
        if isinstance(entry, str):
            name, days = entry, None
        elif isinstance(entry, dict):
            name = str(entry.get("name") or "")
            days = entry.get("days")
        else:
            raise ImportError_(f"Unreadable product entry for {where}: {entry!r}")
        product_id = resolved.get(name)
        if product_id is None:
            continue  # not a covered product; ignored on purpose
        out[product_id] = days_from_list([int(d) for d in days]) if days else None
    return out


def _desired_state(
    payload: Dict[str, Any], resolved: Dict[str, int]
) -> Tuple[Dict[str, str], Dict[str, Dict[AddressKey, Assignment]], Dict[str, List[AddressKey]]]:
    """Returns (display names, street -> address -> assignment, street -> order)."""
    display: Dict[str, str] = {}
    wanted: Dict[str, Dict[AddressKey, Assignment]] = {}
    order: Dict[str, List[AddressKey]] = {}
    for street in payload.get("streets") or []:
        raw_name = str(street.get("name") or "").strip()
        if not raw_name:
            raise ImportError_("A street in the source has no name.")
        key = normalise_street(raw_name)
        display.setdefault(key, raw_name)
        bucket = wanted.setdefault(key, {})
        sequence = order.setdefault(key, [])
        for address in street.get("addresses") or []:
            try:
                number = int(address["number"])
            except (KeyError, TypeError, ValueError):
                raise ImportError_(f"A house in {raw_name} has no usable number: {address!r}") from None
            address_key: AddressKey = (number, _clean_suffix(address.get("suffix")))
            assignment = _parse_products(
                address.get("products"), resolved, f"{raw_name} {number}"
            )
            if address_key in bucket:
                bucket[address_key].update(assignment)
            else:
                bucket[address_key] = assignment
                sequence.append(address_key)
    return display, wanted, order


def apply_import(
    db: sqlite3.Connection,
    payload: Dict[str, Any],
    *,
    dry_run: bool = False,
    force: bool = False,
    max_remove_ratio: float = DEFAULT_MAX_REMOVE_RATIO,
    min_removals_before_guard: int = DEFAULT_MIN_REMOVALS_BEFORE_GUARD,
) -> Dict[str, Any]:
    """Reconcile the route with [payload]. Returns a report; raises ImportError_
    only when the payload itself is unusable."""
    covers = [str(n) for n in (payload.get("covers_products") or [])]
    if not covers:
        raise ImportError_("The source list does not say which products it covers.")
    if not (payload.get("streets") or []):
        raise ImportError_("The source list contains no streets; refusing to empty the route.")

    resolved = _resolve_products(db, covers, load_product_map(db))
    covered_ids = set(resolved.values())
    display, wanted, order = _desired_state(payload, resolved)
    if not any(wanted.values()):
        raise ImportError_("The source list contains no houses; refusing to empty the route.")

    # --- target route
    route_name = payload.get("route")
    if route_name:
        row = db.execute(
            "SELECT * FROM routes WHERE archived=0 AND name=? COLLATE NOCASE", (str(route_name),)
        ).fetchone()
        if row is None:
            raise ImportError_(f"No route named {route_name!r} in Wijkloper.")
    else:
        row = db.execute("SELECT * FROM routes WHERE archived=0 ORDER BY sort_order, id LIMIT 1").fetchone()
        if row is None:
            raise ImportError_("Wijkloper has no route to import into.")
    route_id = row["id"]

    # --- current state for the streets the source covers
    streets = {
        normalise_street(r["name"]): r
        for r in db.execute("SELECT * FROM streets WHERE route_id=?", (route_id,))
    }
    current: Dict[str, Dict[AddressKey, Assignment]] = {}
    address_ids: Dict[str, Dict[AddressKey, int]] = {}
    for key, street in streets.items():
        if key not in wanted:
            continue
        bucket: Dict[AddressKey, Assignment] = {}
        ids: Dict[AddressKey, int] = {}
        for addr in db.execute("SELECT * FROM addresses WHERE street_id=?", (street["id"],)):
            address_key = (addr["number"], _clean_suffix(addr["suffix"]))
            ids[address_key] = addr["id"]
            bucket[address_key] = {
                r["product_id"]: r["days"]
                for r in db.execute(
                    "SELECT product_id, days FROM address_products WHERE address_id=?", (addr["id"],)
                )
                if r["product_id"] in covered_ids
            }
        current[key] = bucket
        address_ids[key] = ids

    # --- diff
    product_names = {
        r["id"]: r["name"] for r in db.execute("SELECT id, name FROM products")
    }
    new_street_keys = {k for k in wanted if k not in streets}
    new_streets = [display[k] for k in new_street_keys]
    records: List[Dict[str, Any]] = []

    def note(kind: str, key: str, address_key: Optional[AddressKey],
             product_id: Optional[int], days: Optional[str], detail: str) -> None:
        records.append({
            "kind": kind,
            "street_name": display[key],
            "number": None if address_key is None else address_key[0],
            "suffix": "" if address_key is None else address_key[1],
            "product_id": product_id,
            "product_name": product_names.get(product_id, "") if product_id else "",
            "days": days,
            "detail": detail,
        })

    for key, houses in wanted.items():
        have = current.get(key, {})
        for address_key, assignment in houses.items():
            existing = have.get(address_key, {})
            for product_id, days in assignment.items():
                if product_id not in existing:
                    note("added", key, address_key, product_id, days, "")
                elif existing[product_id] != days:
                    note("days", key, address_key, product_id, days,
                         f"{existing[product_id] or 'usual days'} -> {days or 'usual days'}")
        for address_key, existing in have.items():
            want = houses.get(address_key, {})
            for product_id in existing:
                if product_id not in want:
                    note("stopped", key, address_key, product_id, None, "")

    def label_of(record: Dict[str, Any]) -> str:
        base = f"{record['street_name']} {record['number']}{record['suffix']}"
        return f"{base} ({record['detail']})" if record["detail"] else base

    added = [label_of(r) for r in records if r["kind"] == "added"]
    changed = [label_of(r) for r in records if r["kind"] == "days"]
    removed = [label_of(r) for r in records if r["kind"] == "stopped"]

    covered_now = sum(len(a) for houses in current.values() for a in houses.values())
    ratio = (len(removed) / covered_now) if covered_now else 0.0
    report: Dict[str, Any] = {
        "source": payload.get("source", "unknown"),
        "district": payload.get("district", ""),
        "fetched_at": payload.get("fetched_at", ""),
        "route": row["name"],
        "covers_products": covers,
        "counts": {
            "streets_in_source": len(wanted),
            "houses_in_source": sum(len(h) for h in wanted.values()),
            "new_streets": len(new_streets),
            "added": len(added),
            "changed": len(changed),
            "removed": len(removed),
            "unchanged": max(0, covered_now - len(removed) - len(changed)),
        },
        "new_streets": new_streets,
        "added": sorted(added),
        "changed": sorted(changed),
        "removed": sorted(removed),
        "remove_ratio": round(ratio, 3),
        "applied": False,
        "ok": True,
    }

    if len(removed) > min_removals_before_guard and ratio > max_remove_ratio and not force:
        report["ok"] = False
        report["error"] = (
            f"Refusing to apply: this would stop {len(removed)} of {covered_now} delivered "
            f"houses ({ratio:.0%}), which looks like a broken source list rather than a real "
            f"change. Re-run with --force if it really is correct."
        )
        _record(db, report, commit=not dry_run)
        return report

    if dry_run:
        _record(db, report, commit=False)
        return report

    # --- apply
    for key, houses in wanted.items():
        street = streets.get(key)
        if street is None:
            position = db.execute(
                "SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM streets WHERE route_id=?",
                (route_id,),
            ).fetchone()["n"]
            # Ascending by default, so a house added later slots into place
            # instead of landing at the end of the street. The source's order is
            # not a walking order anyway; a parent can set one in the app, and
            # the importer never changes it afterwards.
            cur = db.execute(
                "INSERT INTO streets(route_id, name, number_order, sort_order) VALUES (?,?,?,?)",
                (route_id, display[key], "asc", position),
            )
            street_id = cur.lastrowid
            existing_ids: Dict[AddressKey, int] = {}
        else:
            street_id = street["id"]
            existing_ids = address_ids.get(key, {})

        next_order = db.execute(
            "SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM addresses WHERE street_id=?",
            (street_id,),
        ).fetchone()["n"]

        for address_key in order[key]:
            assignment = houses[address_key]
            address_id = existing_ids.get(address_key)
            if address_id is None:
                cur = db.execute(
                    "INSERT INTO addresses(street_id, number, suffix, note, sort_order) VALUES (?,?,?,'',?)",
                    (street_id, address_key[0], address_key[1], next_order),
                )
                address_id = cur.lastrowid
                next_order += 1
            for product_id, days in assignment.items():
                db.execute(
                    "INSERT INTO address_products(address_id, product_id, days) VALUES (?,?,?) "
                    "ON CONFLICT(address_id, product_id) DO UPDATE SET days=excluded.days",
                    (address_id, product_id, days),
                )

        # Stop delivering covered products to houses the source no longer lists.
        for address_key, existing in current.get(key, {}).items():
            want = houses.get(address_key, {})
            for product_id in existing:
                if product_id not in want:
                    db.execute(
                        "DELETE FROM address_products WHERE address_id=? AND product_id=?",
                        (existing_ids[address_key], product_id),
                    )

    _record_changes(db, records, new_street_keys, display)
    report["applied"] = True
    report["version"] = bump_config_version(db)
    _record(db, report, commit=True)
    return report


def _record_changes(
    db: sqlite3.Connection,
    records: List[Dict[str, Any]],
    new_street_keys: Set[str],
    display: Dict[str, str],
) -> None:
    """Write the kid-facing "what's changed" feed.

    A brand new street becomes a single entry rather than one per house, so the
    first import of a round does not bury the feed under fifty notices.
    """
    today = today_local().isoformat()
    stamp = now_iso()
    new_street_names = {display[k] for k in new_street_keys}
    counts = {name: 0 for name in new_street_names}
    for record in records:
        if record["street_name"] in new_street_names:
            if record["kind"] == "added":
                counts[record["street_name"]] += 1
            continue
        db.execute(
            "INSERT INTO route_changes(kind, street_name, number, suffix, product_id, "
            "product_name, days, detail, date, created_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (
                record["kind"], record["street_name"], record["number"], record["suffix"],
                record["product_id"], record["product_name"], record["days"],
                record["detail"], today, stamp,
            ),
        )
    for name in sorted(new_street_names):
        db.execute(
            "INSERT INTO route_changes(kind, street_name, number, suffix, product_id, "
            "product_name, days, detail, date, created_at) VALUES ('street',?,NULL,'',NULL,'',NULL,?,?,?)",
            (name, f"{counts[name]} houses", today, stamp),
        )


# How long a change stays on the "what changed" card: the day it came in and
# the two rounds after it. After that the new state is simply the route.
CHANGE_VISIBLE_DAYS = 3


def recent_changes(db: sqlite3.Connection, *, days: int = CHANGE_VISIBLE_DAYS) -> List[Dict[str, Any]]:
    """Route changes recorded today or on the [days] - 1 days before, newest first."""
    since = (today_local() - dt.timedelta(days=max(days, 1) - 1)).isoformat()
    rows = db.execute(
        "SELECT kind, street_name, number, suffix, product_id, product_name, days, detail, date "
        "FROM route_changes WHERE date >= ? ORDER BY date DESC, street_name, number",
        (since,),
    )
    return [dict(r) for r in rows]


def clear_changes(db: sqlite3.Connection) -> int:
    count = db.execute("SELECT COUNT(*) AS n FROM route_changes").fetchone()["n"]
    db.execute("DELETE FROM route_changes")
    db.commit()
    return count


def _record(db: sqlite3.Connection, report: Dict[str, Any], *, commit: bool) -> None:
    counts = report["counts"]
    summary = (
        f"{counts['added']} added, {counts['removed']} stopped, "
        f"{counts.get('changed', 0)} day changes, {counts['new_streets']} new streets"
    )
    if not report["ok"]:
        summary = "refused: " + str(report.get("error", ""))[:160]
    elif not report["applied"]:
        summary = "dry run: " + summary
    db.execute(
        "INSERT INTO imports(source, district, ran_at, applied, ok, summary, report_json) "
        "VALUES (?,?,?,?,?,?,?)",
        (
            str(report.get("source", "")),
            str(report.get("district", "")),
            now_iso(),
            1 if report["applied"] else 0,
            1 if report["ok"] else 0,
            summary,
            json.dumps(report, ensure_ascii=False),
        ),
    )
    if commit:
        db.commit()


def record_failure(db: sqlite3.Connection, source: str, district: str, error: str) -> None:
    """A run that never got as far as a usable list (portal down, credentials
    missing, broken payload). Recorded so the family can see that last night
    did not happen, instead of a silent gap in the log."""
    db.execute(
        "INSERT INTO imports(source, district, ran_at, applied, ok, summary, report_json) "
        "VALUES (?,?,?,0,0,?,?)",
        (
            source,
            district,
            now_iso(),
            "failed: " + str(error)[:160],
            json.dumps({"ok": False, "applied": False, "error": str(error)}, ensure_ascii=False),
        ),
    )
    db.commit()


def import_status(db: sqlite3.Connection) -> Dict[str, Any]:
    """What the phones show as "subscriber list last updated": the latest
    attempt, which may have failed, and the latest run that really went through."""

    def as_dict(row: Optional[sqlite3.Row]) -> Optional[Dict[str, Any]]:
        if row is None:
            return None
        return {
            "source": row["source"],
            "ran_at": row["ran_at"],
            "ok": bool(row["ok"]),
            "applied": bool(row["applied"]),
            "summary": row["summary"],
        }

    columns = "SELECT source, ran_at, ok, applied, summary FROM imports "
    attempt = db.execute(columns + "ORDER BY ran_at DESC, id DESC LIMIT 1").fetchone()
    applied = db.execute(columns + "WHERE ok=1 AND applied=1 ORDER BY ran_at DESC, id DESC LIMIT 1").fetchone()
    return {"last_attempt": as_dict(attempt), "last_applied": as_dict(applied)}


def recent_imports(db: sqlite3.Connection, limit: int = 20) -> List[Dict[str, Any]]:
    rows = db.execute(
        "SELECT id, source, district, ran_at, applied, ok, summary FROM imports "
        "ORDER BY ran_at DESC, id DESC LIMIT ?",
        (limit,),
    )
    return [dict(r) for r in rows]
