"""Read the delivery list from the spread-it courier portal.

The portal (bezorger.spread-it.nl) is an Angular app over a JSON API, so this
talks to that API directly instead of scraping the page. Only GET requests are
made after logging in; nothing on the portal is modified.

How the portal models a round:

* ``DistributionOrderDistricts`` returns one record per (district, distribution
  order). A distribution order is one product on one date.
* Subscriber papers carry ``distributionOrderAddresses``, the exact houses.
* Advertising leaflets get two records per date: one listing the subscriber
  addresses, and one with only a ``quantity`` for the unaddressed door-to-door
  copies. The second cannot be turned into a house list at all, and the first
  is named after the week it belongs to ("terStal wk 37-38"), so it never maps
  to a stable product.

For those reasons the caller says which products to import by name
(``include_products``). Everything else in the feed is ignored, which keeps any
round you maintain by hand safe from a new leaflet appearing.

A house that only subscribes on some weekdays (the Saturday-only subscribers)
shows up simply by being absent from the other days' orders. We therefore look
at the most recent order for each weekday and record the set of weekdays each
house appears on, which becomes the per-address ``days`` override.
"""
from __future__ import annotations

import datetime as dt
import json
import ssl
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from typing import Any, Dict, List, Optional, Sequence, Set, Tuple

API = "https://api.spread-it.nl/api/"
USER_AGENT = "wijkloper/0.1 (personal paper-route sync)"
DEFAULT_LOOKBACK_DAYS = 28


class PortalError(RuntimeError):
    pass


class SpreaditClient:
    def __init__(self, base_url: str = API, timeout: int = 30) -> None:
        self.base_url = base_url
        self.timeout = timeout
        self.token: Optional[str] = None
        self._context = ssl.create_default_context()

    # --- plumbing -------------------------------------------------------------

    def _request(self, method: str, path: str, body: Any = None, anonymous: bool = False) -> Any:
        url = self.base_url + path
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(url, data=data, method=method)
        request.add_header("Accept", "application/json")
        request.add_header("User-Agent", USER_AGENT)
        if data is not None:
            request.add_header("Content-Type", "application/json")
        if self.token and not anonymous:
            request.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(request, timeout=self.timeout, context=self._context) as response:
                text = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:300]
            raise PortalError(f"{method} {path} failed: HTTP {err.code} {detail}") from None
        except urllib.error.URLError as err:
            raise PortalError(f"{method} {path} failed: {err.reason}") from None
        return json.loads(text) if text.strip() else None

    def login(self, username: str, password: str) -> None:
        """Single attempt on purpose: a wrong password must not be retried."""
        result = self._request(
            "POST", "auth/basic?anonymous=true",
            body={"username": username, "password": password, "application": 1},
            anonymous=True,
        )
        token = (result or {}).get("accessToken")
        if not token:
            raise PortalError("Login succeeded but returned no access token.")
        self.token = token

    # --- reads ----------------------------------------------------------------

    def courier_id(self) -> int:
        principle = self._request("GET", "Principle/Courier") or {}
        inner = principle.get("principle") or {}
        courier = inner.get("courierId") or principle.get("courierId")
        if not courier:
            raise PortalError("Could not find courierId in Principle/Courier.")
        return int(courier)

    def districts(self, courier_id: int) -> List[Dict[str, Any]]:
        rows = self._request("GET", f"CourierDistrict/StreetList/Courier/{courier_id}") or []
        seen: Dict[int, Dict[str, Any]] = {}
        for row in rows:  # the portal repeats a district once per street list
            seen.setdefault(int(row["districtId"]), row)
        return list(seen.values())

    def distribution_orders(self) -> List[Dict[str, Any]]:
        return self._request("GET", "DistributionOrderDistricts") or []


def resolve_district(districts: Sequence[Dict[str, Any]], wanted: str) -> Dict[str, Any]:
    wanted = str(wanted).strip().casefold()
    for row in districts:
        if str(row.get("searchName", "")).strip().casefold() == wanted:
            return row
        if str(row.get("districtId")) == wanted:
            return row
    names = ", ".join(str(r.get("searchName")) for r in districts) or "none"
    raise PortalError(f"District {wanted!r} not found. Available: {names}")


def _date_of(order: Dict[str, Any]) -> dt.date:
    return dt.date.fromisoformat(str(order["distributionOrder"]["distributionDate"])[:10])


def _address_key(entry: Dict[str, Any]) -> Tuple[str, int, str]:
    address = entry.get("address") or {}
    return (
        str(address.get("street", "")).strip(),
        int(address.get("number", 0)),
        str(address.get("numberAddition") or "").strip(),
    )


def _product_name(order: Dict[str, Any]) -> str:
    return str(order["distributionOrder"].get("description") or "").strip()


def build_payload(
    orders: Sequence[Dict[str, Any]],
    district: Dict[str, Any],
    *,
    today: Optional[dt.date] = None,
    lookback_days: int = DEFAULT_LOOKBACK_DAYS,
    include_products: Optional[Sequence[str]] = None,
) -> Dict[str, Any]:
    """Turn raw distribution orders into the normalised import payload.

    [include_products] names the products to import, matched case-insensitively.
    Leave it out only if you really want every product the feed happens to carry.
    """
    today = today or dt.date.today()
    district_id = int(district["districtId"])
    cutoff = today - dt.timedelta(days=lookback_days)
    allowed = (
        None if include_products is None
        else {str(p).strip().casefold() for p in include_products}
    )

    mine = [
        o for o in orders
        if int(o.get("districtId", -1)) == district_id
        # The unaddressed door-to-door records carry no houses; skip them.
        and o.get("distributionOrderAddresses")
        and cutoff <= _date_of(o) <= today
        and (allowed is None or _product_name(o).casefold() in allowed)
    ]
    if not mine:
        wanted = "" if allowed is None else f" for {', '.join(sorted(allowed))}"
        raise PortalError(
            f"No delivery orders with addresses{wanted} for district "
            f"{district.get('searchName')} in the last {lookback_days} days."
        )

    # Most recent order per (product, weekday).
    latest: Dict[Tuple[str, int], Dict[str, Any]] = {}
    names: Dict[str, str] = {}
    for order in mine:
        product_id = str(order["distributionOrder"]["productId"])
        day = _date_of(order)
        key = (product_id, day.isoweekday())
        if key not in latest or _date_of(latest[key]) < day:
            latest[key] = order
        names.setdefault(product_id, _product_name(order))

    # Which weekdays each house receives each product on.
    per_product_days: Dict[str, Set[int]] = defaultdict(set)
    house_days: Dict[Tuple[str, Tuple[str, int, str]], Set[int]] = defaultdict(set)
    for (product_id, weekday), order in latest.items():
        per_product_days[product_id].add(weekday)
        for entry in order["distributionOrderAddresses"]:
            house_days[(product_id, _address_key(entry))].add(weekday)

    streets: Dict[str, Dict[Tuple[int, str], List[Any]]] = defaultdict(dict)
    for (product_id, (street, number, addition)), days in sorted(house_days.items()):
        if not street:
            continue
        usual = per_product_days[product_id]
        entry: Any = names[product_id]
        if days != usual:
            entry = {"name": names[product_id], "days": sorted(days)}
        streets[street].setdefault((number, addition), []).append(entry)

    return {
        "source": "spread-it",
        "district": str(district.get("searchName") or district_id),
        "fetched_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "covers_products": sorted(names[p] for p in per_product_days),
        "streets": [
            {
                "name": street,
                "addresses": [
                    {"number": number, "suffix": addition, "products": products}
                    for (number, addition), products in sorted(houses.items())
                ],
            }
            for street, houses in sorted(streets.items())
        ],
    }


def fetch(username: str, password: str, district: str, *,
          include_products: Optional[Sequence[str]] = None,
          lookback_days: int = DEFAULT_LOOKBACK_DAYS) -> Dict[str, Any]:
    """Log in and return a normalised payload for one district."""
    client = SpreaditClient()
    client.login(username, password)
    chosen = resolve_district(client.districts(client.courier_id()), district)
    return build_payload(
        client.distribution_orders(), chosen,
        lookback_days=lookback_days, include_products=include_products,
    )
