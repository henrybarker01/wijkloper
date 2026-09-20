"""Tests for applying an outside delivery list to the route."""
from __future__ import annotations

import json

import pytest


@pytest.fixture
def db(tmp_path, monkeypatch):
    monkeypatch.setenv("WIJKLOPER_DATA_DIR", str(tmp_path))
    from app import db as dbmod

    dbmod.init_db()
    conn = dbmod.connect()
    try:
        yield conn
    finally:
        conn.close()


def payload(houses, *, street="Nairacstraat", product="Barnevelder", covers=None, **extra):
    """houses: list of numbers, or (number, suffix, [products]) tuples."""
    addresses = []
    for house in houses:
        if isinstance(house, tuple):
            number, suffix, products = house
        else:
            number, suffix, products = house, "", [product]
        addresses.append({"number": number, "suffix": suffix, "products": products})
    body = {
        "source": "test",
        "district": "3772-013",
        "covers_products": covers or [product],
        "streets": [{"name": street, "addresses": addresses}],
    }
    body.update(extra)
    return body


def delivered(db, product_name="Barnevelder"):
    """{(street, number)} currently receiving product_name."""
    rows = db.execute(
        "SELECT s.name AS street, a.number AS number, a.suffix AS suffix FROM address_products ap "
        "JOIN addresses a ON a.id = ap.address_id "
        "JOIN streets s ON s.id = a.street_id "
        "JOIN products p ON p.id = ap.product_id WHERE p.name = ?",
        (product_name,),
    )
    return {(r["street"], r["number"], r["suffix"]) for r in rows}


def test_first_import_creates_street_and_houses(db):
    from app.importer import apply_import

    report = apply_import(db, payload([1, 3, 5, 7]))
    assert report["ok"] and report["applied"]
    assert report["counts"] == {
        "streets_in_source": 1,
        "houses_in_source": 4,
        "new_streets": 1,
        "added": 4,
        "changed": 0,
        "removed": 0,
        "unchanged": 0,
    }
    assert delivered(db) == {("Nairacstraat", n, "") for n in (1, 3, 5, 7)}
    # Ascending by default, so houses added later slot into place rather than
    # landing at the end of the street.
    street = db.execute("SELECT * FROM streets WHERE name='Nairacstraat'").fetchone()
    assert street["number_order"] == "asc"
    order = [r["number"] for r in db.execute(
        "SELECT number FROM addresses WHERE street_id=? ORDER BY sort_order", (street["id"],))]
    assert order == [1, 3, 5, 7]


def test_a_parents_walking_order_survives_later_imports(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3, 5]))
    street_id = db.execute("SELECT id FROM streets WHERE name='Nairacstraat'").fetchone()["id"]
    db.execute("UPDATE streets SET number_order='odd_up_even_back' WHERE id=?", (street_id,))
    db.commit()

    apply_import(db, payload([1, 3, 5, 7]))
    row = db.execute("SELECT number_order FROM streets WHERE id=?", (street_id,)).fetchone()
    assert row["number_order"] == "odd_up_even_back"


def test_reimport_of_the_same_list_changes_nothing(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3, 5]))
    before = db.execute("SELECT value FROM settings WHERE key='config_version'").fetchone()["value"]
    report = apply_import(db, payload([1, 3, 5]))
    assert report["counts"]["added"] == 0
    assert report["counts"]["removed"] == 0
    assert report["counts"]["unchanged"] == 3
    # Nothing changed for the phones beyond the version bump itself.
    assert int(report["version"]) == int(before) + 1


def test_added_and_stopped_subscribers(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3, 5]))
    report = apply_import(db, payload([1, 5, 9]))
    assert report["added"] == ["Nairacstraat 9"]
    assert report["removed"] == ["Nairacstraat 3"]
    assert delivered(db) == {("Nairacstraat", n, "") for n in (1, 5, 9)}
    # The stopped house keeps its row so a parent's note survives.
    assert db.execute("SELECT COUNT(*) AS n FROM addresses").fetchone()["n"] == 4


def test_a_stopped_house_keeps_its_note(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3]))
    db.execute("UPDATE addresses SET note='Big dog' WHERE number=3")
    db.commit()
    apply_import(db, payload([1]))
    row = db.execute("SELECT note FROM addresses WHERE number=3").fetchone()
    assert row["note"] == "Big dog"
    assert delivered(db) == {("Nairacstraat", 1, "")}


def test_partial_list_never_touches_products_it_does_not_cover(db):
    from app.importer import apply_import

    # Thursday: both papers on the round.
    apply_import(
        db,
        payload(
            [(1, "", ["Barnevelder"]), (2, "", ["De Week"]), (4, "", ["De Week"])],
            covers=["Barnevelder", "De Week"],
        ),
    )
    assert delivered(db, "De Week") == {("Nairacstraat", 2, ""), ("Nairacstraat", 4, "")}

    # Monday: only the Barnevelder is delivered, so the list has no De Week houses.
    report = apply_import(db, payload([1], covers=["Barnevelder"]))
    assert report["counts"]["removed"] == 0
    assert delivered(db, "De Week") == {("Nairacstraat", 2, ""), ("Nairacstraat", 4, "")}
    assert delivered(db, "Barnevelder") == {("Nairacstraat", 1, "")}


def test_streets_outside_the_source_are_left_alone(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3], street="Nairacstraat"))
    apply_import(db, payload([2, 4], street="Emmastraat"))
    assert delivered(db) == {
        ("Nairacstraat", 1, ""), ("Nairacstraat", 3, ""),
        ("Emmastraat", 2, ""), ("Emmastraat", 4, ""),
    }
    # A list covering only Emmastraat must not stop Nairacstraat.
    report = apply_import(db, payload([2], street="Emmastraat"))
    assert report["removed"] == ["Emmastraat 4"]
    assert ("Nairacstraat", 1, "") in delivered(db)


def test_suffixes_are_distinct_houses(db):
    from app.importer import apply_import

    apply_import(db, payload([(7, "", ["Barnevelder"]), (7, "a", ["Barnevelder"])]))
    assert delivered(db) == {("Nairacstraat", 7, ""), ("Nairacstraat", 7, "a")}


def test_mass_removal_is_refused_unless_forced(db):
    from app.importer import apply_import

    apply_import(db, payload(list(range(1, 21))))
    report = apply_import(db, payload([1]))
    assert report["ok"] is False
    assert report["applied"] is False
    assert "Refusing to apply" in report["error"]
    assert len(delivered(db)) == 20  # untouched

    forced = apply_import(db, payload([1]), force=True)
    assert forced["applied"] is True
    assert delivered(db) == {("Nairacstraat", 1, "")}


def test_saturday_only_houses_get_a_day_override(db):
    from app.importer import apply_import

    # 1 and 3 every normal day, 37 only on Saturday.
    report = apply_import(db, payload([
        (1, "", ["Barnevelder"]),
        (3, "", ["Barnevelder"]),
        (37, "", [{"name": "Barnevelder", "days": [6]}]),
    ]))
    assert report["counts"]["added"] == 3
    days = {
        r["number"]: r["days"]
        for r in db.execute(
            "SELECT a.number, ap.days FROM address_products ap JOIN addresses a ON a.id=ap.address_id"
        )
    }
    assert days == {1: None, 3: None, 37: "6"}


def test_a_house_moving_to_saturday_only_is_reported_as_a_change(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 37]))
    report = apply_import(db, payload([
        (1, "", ["Barnevelder"]),
        (37, "", [{"name": "Barnevelder", "days": [6]}]),
    ]))
    assert report["counts"] == {
        "streets_in_source": 1, "houses_in_source": 2, "new_streets": 0,
        "added": 0, "changed": 1, "removed": 0, "unchanged": 1,
    }
    assert report["changed"] == ["Nairacstraat 37 (usual days -> 6)"]
    row = db.execute(
        "SELECT ap.days FROM address_products ap JOIN addresses a ON a.id=ap.address_id WHERE a.number=37"
    ).fetchone()
    assert row["days"] == "6"


def test_ordinary_churn_passes_the_guard_even_on_a_small_round(db):
    from app.importer import apply_import

    # 8 stopped houses out of 10 is a big share, but too few houses to look like
    # a broken feed, so it goes through.
    apply_import(db, payload(list(range(1, 11))))
    report = apply_import(db, payload([1, 2]))
    assert report["applied"] is True
    assert report["counts"]["removed"] == 8
    assert delivered(db) == {("Nairacstraat", 1, ""), ("Nairacstraat", 2, "")}


def test_dry_run_reports_without_changing_anything(db):
    from app.importer import apply_import

    apply_import(db, payload([1, 3]))
    report = apply_import(db, payload([1, 3, 5]), dry_run=True)
    assert report["applied"] is False
    assert report["added"] == ["Nairacstraat 5"]
    assert delivered(db) == {("Nairacstraat", 1, ""), ("Nairacstraat", 3, "")}


def test_empty_or_broken_payloads_are_rejected(db):
    from app.importer import ImportError_, apply_import

    with pytest.raises(ImportError_, match="no streets"):
        apply_import(db, {"covers_products": ["Barnevelder"], "streets": []})
    with pytest.raises(ImportError_, match="no houses"):
        apply_import(db, payload([]))
    with pytest.raises(ImportError_, match="which products"):
        apply_import(db, {"streets": [{"name": "X", "addresses": []}]})
    with pytest.raises(ImportError_, match="usable number"):
        apply_import(db, {
            "covers_products": ["Barnevelder"],
            "streets": [{"name": "X", "addresses": [{"suffix": "a"}]}],
        })
    assert db.execute("SELECT COUNT(*) AS n FROM addresses").fetchone()["n"] == 0


def test_unknown_product_names_are_reported_not_guessed(db):
    from app.importer import ImportError_, apply_import

    with pytest.raises(ImportError_, match="Barneveldse Krant"):
        apply_import(db, payload([1], product="Barneveldse Krant"))


def test_product_names_can_be_mapped_from_the_source(db):
    from app.db import set_setting
    from app.importer import PRODUCT_MAP_KEY, apply_import

    set_setting(db, PRODUCT_MAP_KEY, json.dumps({"Barneveldse Krant": "Barnevelder"}))
    db.commit()
    report = apply_import(db, payload([1, 3], product="Barneveldse Krant"))
    assert report["applied"] is True
    assert delivered(db, "Barnevelder") == {("Nairacstraat", 1, ""), ("Nairacstraat", 3, "")}


def test_street_matching_ignores_case_and_spacing(db):
    from app.importer import apply_import

    apply_import(db, payload([1], street="Nairacstraat"))
    report = apply_import(db, payload([1, 3], street="  nairacstraat "))
    assert report["counts"]["new_streets"] == 0
    assert db.execute("SELECT COUNT(*) AS n FROM streets").fetchone()["n"] == 1


def test_a_first_import_records_one_entry_per_street_not_per_house(db):
    from app.importer import apply_import, recent_changes

    apply_import(db, payload(list(range(1, 21))))
    changes = recent_changes(db)
    assert len(changes) == 1
    assert changes[0]["kind"] == "street"
    assert changes[0]["street_name"] == "Nairacstraat"
    assert changes[0]["detail"] == "20 houses"


def test_later_changes_are_listed_per_house_for_the_kids(db):
    from app.importer import apply_import, clear_changes, recent_changes

    apply_import(db, payload([1, 3, 5]))
    clear_changes(db)  # the initial load is not news

    apply_import(db, payload([
        (1, "", ["Barnevelder"]),
        (5, "", [{"name": "Barnevelder", "days": [6]}]),
        (9, "", ["Barnevelder"]),
    ]))
    by_kind = {c["kind"]: c for c in recent_changes(db)}
    assert set(by_kind) == {"added", "stopped", "days"}
    assert (by_kind["added"]["number"], by_kind["added"]["street_name"]) == (9, "Nairacstraat")
    assert by_kind["stopped"]["number"] == 3
    assert by_kind["days"]["number"] == 5
    assert by_kind["days"]["days"] == "6"
    assert by_kind["added"]["product_name"] == "Barnevelder"


def test_a_dry_run_records_no_changes_for_the_kids(db):
    from app.importer import apply_import, clear_changes, recent_changes

    apply_import(db, payload([1]))
    clear_changes(db)
    apply_import(db, payload([1, 3]), dry_run=True)
    assert recent_changes(db) == []


def test_changes_can_be_cleared(db):
    from app.importer import apply_import, clear_changes, recent_changes

    apply_import(db, payload([1, 3]))
    assert clear_changes(db) == 1
    assert recent_changes(db) == []


def test_every_run_is_recorded(db):
    from app.importer import apply_import, recent_imports

    apply_import(db, payload([1, 3]))
    apply_import(db, payload([1, 3, 5]), dry_run=True)
    history = recent_imports(db)
    assert len(history) == 2
    assert history[0]["summary"].startswith("dry run")
    assert all(row["source"] == "test" and row["district"] == "3772-013" for row in history)
