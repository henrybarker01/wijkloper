"""Personal bests, streaks and the family leaderboard, computed from stored runs."""
from __future__ import annotations

import datetime as dt
import json
import sqlite3
from typing import Any, Dict, List, Optional, Set

from .db import days_to_list, today_local


def run_to_dict(r: sqlite3.Row) -> Dict[str, Any]:
    try:
        papers = json.loads(r["papers_json"] or "{}")
    except ValueError:
        papers = {}
    paper_count = 0
    for value in papers.values():
        if isinstance(value, dict):
            try:
                paper_count += int(value.get("count", 0))
            except (TypeError, ValueError):
                pass
    return {
        "id": r["id"],
        "client_run_id": r["client_run_id"],
        "kid_id": r["kid_id"],
        "route_id": r["route_id"],
        "date": r["date"],
        "weekday": r["weekday"],
        "started_at": r["started_at"],
        "finished_at": r["finished_at"],
        "duration_seconds": r["duration_seconds"],
        "stops_total": r["stops_total"],
        "stops_done": r["stops_done"],
        "completed": r["stops_total"] > 0 and r["stops_done"] >= r["stops_total"],
        "papers": papers,
        "paper_count": paper_count,
    }


def scheduled_weekdays(db: sqlite3.Connection) -> Set[int]:
    """Weekdays on which anything at all is delivered (used for streaks)."""
    days: Set[int] = set()
    for r in db.execute("SELECT days FROM products WHERE archived=0"):
        days.update(days_to_list(r["days"]) or [])
    for r in db.execute("SELECT DISTINCT days FROM address_products WHERE days IS NOT NULL"):
        days.update(days_to_list(r["days"]) or [])
    return days


def compute_streak(run_dates: Set[str], scheduled: Set[int], today: dt.date) -> int:
    """Consecutive scheduled days with a run, counting back from today.

    Today does not break the streak while it is still pending.
    """
    if not scheduled:
        return 0
    day = today
    if day.isoweekday() in scheduled and day.isoformat() not in run_dates:
        day = day - dt.timedelta(days=1)
    streak = 0
    for _ in range(3660):  # cap at ~10 years
        if day.isoweekday() in scheduled:
            if day.isoformat() in run_dates:
                streak += 1
            else:
                break
        day -= dt.timedelta(days=1)
    return streak


def best_by_weekday(runs: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Fastest completed run per ISO weekday (keys are strings for JSON)."""
    best: Dict[str, Dict[str, Any]] = {}
    for run in runs:
        if not run["completed"]:
            continue
        key = str(run["weekday"])
        if key not in best or run["duration_seconds"] < best[key]["duration_seconds"]:
            best[key] = {
                "duration_seconds": run["duration_seconds"],
                "date": run["date"],
                "run_id": run["id"],
                "stops_total": run["stops_total"],
            }
    return best


def _runs_for_kid(db: sqlite3.Connection, kid_id: int) -> List[Dict[str, Any]]:
    rows = db.execute(
        "SELECT * FROM runs WHERE kid_id=? ORDER BY date DESC, started_at DESC", (kid_id,)
    ).fetchall()
    return [run_to_dict(r) for r in rows]


def _summary(runs: List[Dict[str, Any]], scheduled: Set[int], today: dt.date) -> Dict[str, Any]:
    return {
        "totals": {
            "runs": len(runs),
            "completed_runs": sum(1 for r in runs if r["completed"]),
            "papers": sum(r["paper_count"] for r in runs),
            "seconds": sum(r["duration_seconds"] for r in runs),
        },
        "streak_days": compute_streak({r["date"] for r in runs}, scheduled, today),
        "best_by_weekday": best_by_weekday(runs),
        "today_done": any(r["date"] == today.isoformat() for r in runs),
    }


def compute_stats(db: sqlite3.Connection, kid_id: Optional[int]) -> Dict[str, Any]:
    today = today_local()
    scheduled = scheduled_weekdays(db)
    result: Dict[str, Any] = {
        "kid_id": kid_id,
        "today": today.isoformat(),
        "scheduled_weekdays": sorted(scheduled),
    }
    if kid_id is not None:
        runs = _runs_for_kid(db, kid_id)
        result.update(_summary(runs, scheduled, today))
        result["recent"] = runs[:15]

    leaderboard = []
    for kid in db.execute("SELECT * FROM kids WHERE archived=0 ORDER BY sort_order, id"):
        kid_runs = _runs_for_kid(db, kid["id"])
        entry = {
            "kid_id": kid["id"],
            "name": kid["name"],
            "emoji": kid["emoji"],
            "color": kid["color"],
        }
        entry.update(_summary(kid_runs, scheduled, today))
        leaderboard.append(entry)
    result["leaderboard"] = leaderboard
    return result
