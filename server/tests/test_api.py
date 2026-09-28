"""End-to-end test of the API through FastAPI's TestClient (in-process, temp database)."""
from __future__ import annotations

import datetime as dt
import os
import uuid

import pytest
from fastapi.testclient import TestClient


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    os.environ["WIJKLOPER_DATA_DIR"] = str(tmp_path_factory.mktemp("data"))
    os.environ["WIJKLOPER_PAIRING_CODE"] = "123456"
    os.environ["WIJKLOPER_PARENT_PIN"] = "1234"
    os.environ["WIJKLOPER_FAIL_DELAY"] = "0"
    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="module")
def device(client):
    r = client.post("/api/pair", json={"pairing_code": "123456", "device_name": "Test phone"})
    assert r.status_code == 200, r.text
    return {"Authorization": "Bearer " + r.json()["device_token"]}


@pytest.fixture(scope="module")
def parent(client, device):
    r = client.post("/api/parent/login", json={"pin": "1234"}, headers=device)
    assert r.status_code == 200, r.text
    headers = dict(device)
    headers["X-Parent-Token"] = r.json()["parent_token"]
    return headers


def test_health_and_index(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json()["app"] == "wijkloper"
    assert "Wijkloper" in client.get("/").text


def test_pairing_rejects_wrong_code(client):
    r = client.post("/api/pair", json={"pairing_code": "000000"})
    assert r.status_code == 401


def test_config_requires_device_token(client):
    assert client.get("/api/config").status_code == 401
    assert client.get("/api/config", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_default_config(client, device):
    r = client.get("/api/config", headers=device)
    assert r.status_code == 200
    cfg = r.json()
    names = [p["name"] for p in cfg["products"]]
    assert names == ["Barnevelder", "Folders", "De Week"]
    assert cfg["products"][0]["days"] == [1, 2, 3, 4, 5, 6]
    assert cfg["products"][1]["kind"] == "insert"
    assert len(cfg["routes"]) == 1
    assert cfg["version"] == 1


def test_parent_login_rejects_wrong_pin(client, device):
    r = client.post("/api/parent/login", json={"pin": "9999"}, headers=device)
    assert r.status_code == 403


def test_admin_requires_parent_token(client, device):
    r = client.post("/api/admin/kids", json={"name": "Nope"}, headers=device)
    assert r.status_code == 403


def test_full_route_setup_flow(client, device, parent):
    cfg = client.get("/api/config", headers=device).json()
    route_id = cfg["routes"][0]["id"]
    products = {p["name"]: p["id"] for p in cfg["products"]}
    barnevelder, folders, de_week = products["Barnevelder"], products["Folders"], products["De Week"]

    # Kids
    r = client.post("/api/admin/kids", json={"name": "Sam", "emoji": "🚴", "color": "#2563EB"}, headers=parent)
    assert r.status_code == 200, r.text
    sam = r.json()["id"]
    r = client.post("/api/admin/kids", json={"name": "Mila", "emoji": "⚡", "color": "#DB2777"}, headers=parent)
    mila = r.json()["id"]
    r = client.put("/api/admin/kids/order", json={"ids": [mila, sam]}, headers=parent)
    assert r.status_code == 200, r.text

    # Street with numbers 1..20, odd numbers walked up and even numbers back.
    r = client.post(
        "/api/admin/routes/%d/streets" % route_id,
        json={"name": "Kerkstraat", "number_order": "odd_up_even_back"},
        headers=parent,
    )
    assert r.status_code == 200, r.text
    street = r.json()["id"]
    r = client.post(
        "/api/admin/streets/%d/addresses/bulk" % street,
        json={"start": 1, "end": 20, "parity": "all", "products": [{"product_id": barnevelder}]},
        headers=parent,
    )
    assert r.status_code == 200, r.text
    assert r.json()["created"] == 20
    # Re-adding the same range skips duplicates.
    r = client.post(
        "/api/admin/streets/%d/addresses/bulk" % street,
        json={"start": 1, "end": 5, "parity": "all"},
        headers=parent,
    )
    assert r.json() == {**r.json(), "created": 0, "skipped": 5}

    cfg = client.get("/api/config", headers=device).json()
    addresses = {a["number"]: a for a in cfg["addresses"] if a["street_id"] == street}
    assert len(addresses) == 20
    assert addresses[7]["products"] == [{"product_id": barnevelder, "days": None}]

    # Paint mode: folders for numbers 1-10, De Week instead of Barnevelder for 11-20.
    low = [addresses[n]["id"] for n in range(1, 11)]
    high = [addresses[n]["id"] for n in range(11, 21)]
    r = client.put("/api/admin/assignments", json={"address_ids": low, "product_id": folders}, headers=parent)
    assert r.status_code == 200, r.text
    client.put("/api/admin/assignments", json={"address_ids": high, "product_id": barnevelder, "assigned": False}, headers=parent)
    client.put("/api/admin/assignments", json={"address_ids": high, "product_id": de_week}, headers=parent)
    # Number 20 only gets the Barnevelder on Saturdays.
    r = client.put(
        "/api/admin/assignments",
        json={"address_ids": [addresses[20]["id"]], "product_id": barnevelder, "days": [6]},
        headers=parent,
    )
    assert r.status_code == 200, r.text

    cfg2 = client.get("/api/config", headers=device).json()
    assert cfg2["version"] > cfg["version"]
    addresses = {a["number"]: a for a in cfg2["addresses"] if a["street_id"] == street}
    assert {p["product_id"] for p in addresses[3]["products"]} == {barnevelder, folders}
    assert {p["product_id"] for p in addresses[15]["products"]} == {de_week}
    twenty = {p["product_id"]: p["days"] for p in addresses[20]["products"]}
    assert twenty == {barnevelder: [6], de_week: None}

    # Unchanged short-circuit.
    r = client.get("/api/config?known_version=%d" % cfg2["version"], headers=device)
    assert r.json() == {"unchanged": True, "version": cfg2["version"]}

    # Edit a single address: note + explicit product list.
    r = client.put(
        "/api/admin/addresses/%d" % addresses[7]["id"],
        json={"note": "Big dog!", "products": [{"product_id": barnevelder, "days": None}]},
        headers=parent,
    )
    assert r.status_code == 200, r.text
    cfg3 = client.get("/api/config", headers=device).json()
    seven = next(a for a in cfg3["addresses"] if a["id"] == addresses[7]["id"])
    assert seven["note"] == "Big dog!"
    assert [p["product_id"] for p in seven["products"]] == [barnevelder]

    # Duplicate house number is rejected.
    r = client.post("/api/admin/streets/%d/addresses" % street, json={"number": 7}, headers=parent)
    assert r.status_code == 409
    r = client.post("/api/admin/streets/%d/addresses" % street, json={"number": 7, "suffix": "a"}, headers=parent)
    assert r.status_code == 200

    # Upload a run for Sam on a Thursday and check stats.
    thursday = dt.date(2026, 9, 17)
    run = {
        "client_run_id": str(uuid.uuid4()),
        "kid_id": sam,
        "route_id": route_id,
        "date": thursday.isoformat(),
        "weekday": 4,
        "started_at": "2026-09-17T16:00:00+02:00",
        "finished_at": "2026-09-17T16:25:30+02:00",
        "duration_seconds": 1530,
        "stops_total": 21,
        "stops_done": 21,
        "papers": {str(barnevelder): {"name": "Barnevelder", "count": 11}, str(de_week): {"name": "De Week", "count": 10}},
        "events": [{"address_id": addresses[1]["id"], "t": 40}],
    }
    r = client.post("/api/runs", json=run, headers=device)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["duplicate"] is False
    assert body["stats"]["best_by_weekday"]["4"]["duration_seconds"] == 1530
    assert body["stats"]["totals"]["papers"] == 21

    # Same run again is a no-op.
    r = client.post("/api/runs", json=run, headers=device)
    assert r.json()["duplicate"] is True
    assert client.get("/api/runs?kid_id=%d" % sam, headers=device).json()["runs"][0]["completed"] is True

    # A faster but incomplete run must not become the personal best.
    run2 = dict(run, client_run_id=str(uuid.uuid4()), duration_seconds=900, stops_done=19, date="2026-09-10")
    client.post("/api/runs", json=run2, headers=device)
    stats = client.get("/api/stats?kid_id=%d" % sam, headers=device).json()
    assert stats["best_by_weekday"]["4"]["duration_seconds"] == 1530
    assert stats["totals"]["runs"] == 2
    assert [k["name"] for k in stats["leaderboard"]] == ["Mila", "Sam"]

    # Deleting a kid with runs archives instead of deleting.
    r = client.delete("/api/admin/kids/%d" % sam, headers=parent)
    assert r.json()["archived"] is True
    assert [k["name"] for k in client.get("/api/config", headers=device).json()["kids"]] == ["Mila"]

    # Deleting the street cascades to its addresses.
    client.delete("/api/admin/streets/%d" % street, headers=parent)
    assert client.get("/api/config", headers=device).json()["addresses"] == []

    # Devices & settings.
    devices = client.get("/api/admin/devices", headers=parent).json()["devices"]
    assert devices[0]["name"] == "Test phone"
    r = client.put("/api/admin/settings", json={"family_name": "Familie Test", "new_pin": "4321"}, headers=parent)
    assert r.status_code == 200
    assert client.get("/api/health").json()["family_name"] == "Familie Test"
    assert client.post("/api/parent/login", json={"pin": "1234"}, headers=device).status_code == 403
    assert client.post("/api/parent/login", json={"pin": "4321"}, headers=device).status_code == 200


def test_streak_logic():
    from app.stats import compute_streak

    scheduled = {1, 2, 3, 4, 5, 6}  # Monday..Saturday
    friday = dt.date(2026, 9, 18)
    # Mon-Thu done this week, Friday (today) not yet -> streak 4, and Sunday gap is skipped.
    dates = {"2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17", "2026-09-12"}
    assert compute_streak(dates, scheduled, friday) == 5
    # Missing Wednesday breaks it.
    assert compute_streak(dates - {"2026-09-16"}, scheduled, friday) == 1
    assert compute_streak(set(), scheduled, friday) == 0
    assert compute_streak(dates, set(), friday) == 0


def test_extra_delivery_days(client, device, parent):
    cfg = client.get("/api/config", headers=device).json()
    route_id = cfg["routes"][0]["id"]
    barnevelder = next(p["id"] for p in cfg["products"] if p["name"] == "Barnevelder")
    street = client.post("/api/admin/routes/%d/streets" % route_id, json={"name": "Extrastraat"}, headers=parent).json()["id"]
    client.post("/api/admin/streets/%d/addresses/bulk" % street, json={"start": 1, "end": 4}, headers=parent)
    houses = [a["id"] for a in client.get("/api/config", headers=device).json()["addresses"] if a["street_id"] == street]

    far_future = (dt.date.today() + dt.timedelta(days=30)).isoformat()
    later = (dt.date.today() + dt.timedelta(days=37)).isoformat()
    r = client.post(
        "/api/admin/extras",
        json={"product_id": barnevelder, "dates": [later, far_future, far_future], "address_ids": houses[:3] + [999999], "note": "Special edition"},
        headers=parent,
    )
    assert r.status_code == 200, r.text
    ids = r.json()["ids"]
    assert len(ids) == 2  # duplicate date collapsed, one row per date

    extras = client.get("/api/config", headers=device).json()["extras"]
    assert [e["date"] for e in extras] == [far_future, later]
    assert extras[0]["address_ids"] == sorted(houses[:3])  # unknown id dropped
    assert extras[0]["note"] == "Special edition"

    # Past extras stay in the admin list but not in the phone config.
    old = client.post(
        "/api/admin/extras",
        json={"product_id": barnevelder, "dates": ["2020-01-01"], "address_ids": houses[:1]},
        headers=parent,
    ).json()["ids"][0]
    assert all(e["id"] != old for e in client.get("/api/config", headers=device).json()["extras"])
    assert any(e["id"] == old for e in client.get("/api/admin/extras", headers=parent).json()["extras"])

    # Update houses and note, then delete.
    r = client.put("/api/admin/extras/%d" % ids[0], json={"address_ids": houses, "note": "All houses"}, headers=parent)
    assert r.status_code == 200, r.text
    assert r.json()["extra"]["address_ids"] == sorted(houses)
    assert client.put("/api/admin/extras/%d" % ids[0], json={"address_ids": []}, headers=parent).status_code == 400
    assert client.post("/api/admin/extras", json={"product_id": barnevelder, "dates": ["nonsense"], "address_ids": houses}, headers=parent).status_code == 422
    for extra_id in ids + [old]:
        assert client.delete("/api/admin/extras/%d" % extra_id, headers=parent).status_code == 200
    assert client.get("/api/admin/extras", headers=parent).json()["extras"] == []
    client.delete("/api/admin/streets/%d" % street, headers=parent)


def test_kid_can_mark_and_clear_a_nee_nee_sticker(client, device, parent):
    cfg = client.get("/api/config", headers=device).json()
    route_id = cfg["routes"][0]["id"]
    street = client.post("/api/admin/routes/%d/streets" % route_id, json={"name": "Stickerstraat"}, headers=parent).json()["id"]
    house = client.post("/api/admin/streets/%d/addresses" % street, json={"number": 12}, headers=parent).json()["id"]
    before = client.get("/api/config", headers=device).json()
    assert next(a for a in before["addresses"] if a["id"] == house)["sticker"] == ""

    # A kid, with only the device token, marks the sticker.
    r = client.put("/api/addresses/%d/sticker" % house, json={"sticker": "nee_nee"}, headers=device)
    assert r.status_code == 200, r.text
    assert r.json()["unchanged"] is False
    after = client.get("/api/config", headers=device).json()
    assert after["version"] > before["version"]
    assert next(a for a in after["addresses"] if a["id"] == house)["sticker"] == "nee_nee"
    # The other phones learn about it through the change feed.
    change = next(c for c in after["changes"] if c["kind"] == "sticker")
    assert (change["street_name"], change["number"]) == ("Stickerstraat", 12)
    assert "skip" in change["detail"]

    # Same value again is a no-op that does not bump the version.
    r = client.put("/api/addresses/%d/sticker" % house, json={"sticker": "nee_nee"}, headers=device)
    assert r.json()["unchanged"] is True

    # Sticker gone: the house is delivered again. Undoing today's own mark is a
    # slip of the thumb, so the feed forgets the whole thing instead of showing
    # "skip" and "deliver again" for the same door.
    r = client.put("/api/addresses/%d/sticker" % house, json={"sticker": ""}, headers=device)
    assert r.json()["unchanged"] is False
    final = client.get("/api/config", headers=device).json()
    assert next(a for a in final["addresses"] if a["id"] == house)["sticker"] == ""
    assert [c for c in final["changes"] if c["kind"] == "sticker"] == []

    # A sticker that was marked on an earlier day and is now gone is news.
    client.put("/api/addresses/%d/sticker" % house, json={"sticker": "nee_nee"}, headers=device)
    from app.db import connect

    db = connect()
    try:
        db.execute("UPDATE route_changes SET date=? WHERE kind='sticker'", ("2020-01-01",))
        db.commit()
    finally:
        db.close()
    client.put("/api/addresses/%d/sticker" % house, json={"sticker": ""}, headers=device)
    stickers = [c for c in client.get("/api/config", headers=device).json()["changes"] if c["kind"] == "sticker"]
    assert len(stickers) == 1 and "deliver again" in stickers[0]["detail"]

    # Unknown stickers and unknown houses are rejected.
    assert client.put("/api/addresses/%d/sticker" % house, json={"sticker": "ja_ja"}, headers=device).status_code == 422
    assert client.put("/api/addresses/999999/sticker", json={"sticker": "nee_nee"}, headers=device).status_code == 404
    # And it needs a device token.
    assert client.put("/api/addresses/%d/sticker" % house, json={"sticker": "nee_nee"}).status_code == 401

    # Parents can set it too, through the normal address edit.
    r = client.put("/api/admin/addresses/%d" % house, json={"sticker": "nee_nee"}, headers=parent)
    assert r.status_code == 200, r.text
    assert next(a for a in client.get("/api/config", headers=device).json()["addresses"] if a["id"] == house)["sticker"] == "nee_nee"
    client.delete("/api/admin/streets/%d" % street, headers=parent)


def test_pairing_locks_out_after_repeated_failures(client):
    from app.ratelimit import pair_limiter

    pair_limiter.reset_all()
    for _ in range(pair_limiter.max_failures):
        assert client.post("/api/pair", json={"pairing_code": "000000"}).status_code == 401
    assert client.post("/api/pair", json={"pairing_code": "000000"}).status_code == 429
    # Even the right code is refused until the window has passed.
    assert client.post("/api/pair", json={"pairing_code": "123456"}).status_code == 429
    pair_limiter.reset_all()
    assert client.post("/api/pair", json={"pairing_code": "123456"}).status_code == 200


def test_pin_locks_out_after_repeated_failures(client, device):
    from app.ratelimit import pin_limiter

    pin_limiter.reset_all()
    for _ in range(pin_limiter.max_failures):
        assert client.post("/api/parent/login", json={"pin": "0000"}, headers=device).status_code == 403
    r = client.post("/api/parent/login", json={"pin": "0000"}, headers=device)
    assert r.status_code == 429
    assert "Try again" in r.json()["detail"]
    pin_limiter.reset_all()
