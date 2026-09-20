"""Tests for turning the portal's distribution orders into an import payload."""
from __future__ import annotations

import datetime as dt

import pytest

from app.sources.spreadit import PortalError, build_payload, resolve_district

DISTRICT = {"districtId": 628006, "searchName": "3772-013"}
KRANT = "aaf96931-c35d-41b1-aca5-7c178baad161"
LEAFLET = "d70c4cd5-53e9-4117-b5a1-0aa4b7a55c28"
TODAY = dt.date(2026, 9, 21)  # a Monday


def order(date, product_id, houses, *, district_id=628006, description="Barneveldse Krant"):
    return {
        "districtId": district_id,
        "subscriptionQuantity": len(houses),
        "distributionOrder": {
            "productId": product_id,
            "description": description,
            "distributionDate": f"{date}T00:00:00",
        },
        "distributionOrderAddresses": [
            {"quantity": 1, "address": {"street": s, "number": n, "numberAddition": a}}
            for s, n, a in houses
        ],
    }


BASE = [("Nairacstraat", 1, ""), ("Nairacstraat", 3, ""), ("Emmastraat", 15, "")]
SAT_EXTRA = [("Nairacstraat", 37, ""), ("De Heus Plein", 65, "")]


def week_of_orders(monday: dt.date, base=BASE, sat_extra=SAT_EXTRA):
    """Mon-Sat orders; Saturday also carries the extra houses."""
    out = []
    for offset in range(6):  # Mon..Sat
        day = monday + dt.timedelta(days=offset)
        houses = base + (sat_extra if day.isoweekday() == 6 else [])
        out.append(order(day.isoformat(), KRANT, houses))
    return out


def test_saturday_only_houses_become_a_day_override():
    orders = week_of_orders(dt.date(2026, 9, 14))
    payload = build_payload(orders, DISTRICT, today=TODAY)

    assert payload["source"] == "spread-it"
    assert payload["district"] == "3772-013"
    assert payload["covers_products"] == ["Barneveldse Krant"]

    houses = {
        (street["name"], a["number"]): a["products"]
        for street in payload["streets"] for a in street["addresses"]
    }
    # Everyday subscribers inherit the product's usual days.
    assert houses[("Nairacstraat", 1)] == ["Barneveldse Krant"]
    assert houses[("Emmastraat", 15)] == ["Barneveldse Krant"]
    # Saturday-only subscribers carry an explicit day list (6 = Saturday).
    assert houses[("Nairacstraat", 37)] == [{"name": "Barneveldse Krant", "days": [6]}]
    assert houses[("De Heus Plein", 65)] == [{"name": "Barneveldse Krant", "days": [6]}]


def test_unaddressed_door_to_door_records_are_ignored():
    orders = week_of_orders(dt.date(2026, 9, 14))
    orders.append({
        "districtId": 628006,
        "subscriptionQuantity": 0,
        "distributionOrder": {
            "productId": LEAFLET, "description": "Domino's Pizza wk 38",
            "distributionDate": "2026-09-17T00:00:00",
        },
        "distributionOrderAddresses": [],
    })
    payload = build_payload(orders, DISTRICT, today=TODAY)
    assert payload["covers_products"] == ["Barneveldse Krant"]


def test_only_the_named_products_are_imported():
    # Leaflets do carry subscriber addresses, but their names change every week,
    # so an explicit list keeps them out of the route.
    orders = week_of_orders(dt.date(2026, 9, 14))
    orders.append(order("2026-09-17", LEAFLET, BASE, description="terStal wk 37-38 (DRS)"))

    everything = build_payload(orders, DISTRICT, today=TODAY)
    assert "terStal wk 37-38 (DRS)" in everything["covers_products"]

    payload = build_payload(orders, DISTRICT, today=TODAY,
                            include_products=["Barneveldse Krant"])
    assert payload["covers_products"] == ["Barneveldse Krant"]
    for street in payload["streets"]:
        for address in street["addresses"]:
            for product in address["products"]:
                name = product["name"] if isinstance(product, dict) else product
                assert name == "Barneveldse Krant"


def test_a_missing_named_product_is_an_error_not_an_empty_route():
    orders = week_of_orders(dt.date(2026, 9, 14))
    with pytest.raises(PortalError, match="No delivery orders"):
        build_payload(orders, DISTRICT, today=TODAY, include_products=["De Week"])


def test_other_districts_are_ignored():
    orders = week_of_orders(dt.date(2026, 9, 14))
    orders.append(order("2026-09-16", KRANT, [("Elders", 9, "")], district_id=628015))
    payload = build_payload(orders, DISTRICT, today=TODAY)
    assert all(s["name"] != "Elders" for s in payload["streets"])


def test_only_the_most_recent_order_per_weekday_counts():
    # An old Monday had house 99; the latest Monday does not. It must not appear.
    orders = week_of_orders(dt.date(2026, 9, 14))
    orders.insert(0, order("2026-09-07", KRANT, BASE + [("Nairacstraat", 99, "")]))
    payload = build_payload(orders, DISTRICT, today=TODAY)
    numbers = {a["number"] for s in payload["streets"] for a in s["addresses"]}
    assert 99 not in numbers


def test_orders_outside_the_lookback_window_are_ignored():
    orders = week_of_orders(dt.date(2026, 6, 1))  # months ago
    with pytest.raises(PortalError, match="No delivery orders"):
        build_payload(orders, DISTRICT, today=TODAY, lookback_days=28)


def test_house_number_additions_are_kept():
    orders = [order("2026-09-19", KRANT, [("Kampstraat", 7, "a"), ("Kampstraat", 7, "")])]
    payload = build_payload(orders, DISTRICT, today=TODAY)
    street = payload["streets"][0]
    assert [(a["number"], a["suffix"]) for a in street["addresses"]] == [(7, ""), (7, "a")]


def test_resolve_district_by_code_or_id():
    districts = [DISTRICT, {"districtId": 628015, "searchName": "3772-030"}]
    assert resolve_district(districts, "3772-013")["districtId"] == 628006
    assert resolve_district(districts, "628015")["districtId"] == 628015
    with pytest.raises(PortalError, match="not found"):
        resolve_district(districts, "9999-999")
