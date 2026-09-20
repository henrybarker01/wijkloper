#!/usr/bin/env python3
"""Read-only probe of the spread-it courier portal API.

Confirms the response shapes we need before building the daily import. It logs
in once, then only performs GET requests. It never calls the document/PDF
endpoint or anything else that changes state on the portal.

Credentials come from tools/.env (see .env.example) or the environment; they are
never written to the output files and never printed.

    python spreadit_probe.py --district 3772-013

By default the dump is *sampled*: long lists are cut to a few entries and long
strings truncated, so the file shows the structure without copying the whole
subscriber list. Use --full when you want the complete data.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Optional

API = "https://api.spread-it.nl/api/"
USER_AGENT = "wijkloper-probe/0.1 (personal route sync; contact: the account owner)"

# Anything matching these key names is replaced before writing to disk.
SECRET_KEY = re.compile(r"token|password|secret|bsn|iban|apikey|authorization", re.I)
# Bare JWTs that might show up inside string values.
JWT = re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+")


class ApiError(RuntimeError):
    def __init__(self, status: int, body: str) -> None:
        super().__init__(f"HTTP {status}: {body[:400]}")
        self.status = status
        self.body = body


def load_env(path: str) -> None:
    """Minimal .env reader: KEY=value lines, # comments, no export/quoting magic."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def call(method: str, url: str, token: Optional[str] = None, body: Any = None,
         timeout: int = 30) -> Any:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/json")
    request.add_header("User-Agent", USER_AGENT)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            text = response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        raise ApiError(err.code, err.read().decode("utf-8", "replace")) from None
    if not text.strip():
        return None
    try:
        return json.loads(text)
    except ValueError:
        return {"_raw": text[:2000]}


def redact(value: Any, *, full: bool, max_items: int = 4, max_str: int = 300,
           _key: str = "") -> Any:
    """Strip secrets and (unless full) sample long lists/strings."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            if SECRET_KEY.search(key):
                out[key] = "<redacted>"
            else:
                out[key] = redact(item, full=full, max_items=max_items, max_str=max_str, _key=key)
        return out
    if isinstance(value, list):
        items = value if full else value[:max_items]
        result = [redact(v, full=full, max_items=max_items, max_str=max_str, _key=_key) for v in items]
        if not full and len(value) > len(items):
            result.append(f"<+{len(value) - len(items)} more of {len(value)} total>")
        return result
    if isinstance(value, str):
        cleaned = JWT.sub("<jwt>", value)
        if not full and len(cleaned) > max_str:
            return cleaned[:max_str] + f"<+{len(cleaned) - max_str} chars>"
        return cleaned
    return value


def write(out_dir: str, name: str, payload: Any, *, full: bool) -> str:
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, name)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(redact(payload, full=full), handle, indent=2, ensure_ascii=False)
    return path


def summarise(label: str, value: Any) -> None:
    if isinstance(value, list):
        print(f"  {label}: list of {len(value)}")
        if value and isinstance(value[0], dict):
            keys = ", ".join(sorted(value[0].keys())[:14])
            print(f"      keys: {keys}")
    elif isinstance(value, dict):
        print(f"  {label}: object with keys: {', '.join(sorted(value.keys())[:14])}")
    else:
        print(f"  {label}: {type(value).__name__}")


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--district", default="3772-013",
                        help="District code to probe in depth (default: 3772-013)")
    parser.add_argument("--out", default=os.path.join(here, "out"), help="Output directory")
    parser.add_argument("--full", action="store_true",
                        help="Write complete data instead of a sampled structure")
    parser.add_argument("--env", default=os.path.join(here, ".env"), help="Path to the .env file")
    args = parser.parse_args()

    load_env(args.env)
    username = os.environ.get("SPREADIT_USERNAME")
    password = os.environ.get("SPREADIT_PASSWORD")
    if not username or not password:
        print("Missing credentials. Copy tools/.env.example to tools/.env and fill it in.", file=sys.stderr)
        return 2

    # --- one login attempt only, so a wrong password can never lock the account
    print(f"Logging in as {username[:2]}{'*' * max(0, len(username) - 2)} ...")
    try:
        auth = call("POST", API + "auth/basic?anonymous=true",
                    body={"username": username, "password": password, "application": 1})
    except ApiError as err:
        print(f"Login failed ({err.status}). The portal said:\n{err.body[:600]}", file=sys.stderr)
        print("\nNot retrying, so your account is not at risk of a lockout.", file=sys.stderr)
        return 1
    token = (auth or {}).get("accessToken")
    if not token:
        print("Login returned no accessToken. Keys: " + ", ".join(sorted((auth or {}).keys())), file=sys.stderr)
        return 1
    print("  ok, got an access token")

    results: dict[str, Any] = {}

    principle = call("GET", API + "Principle/Courier", token)
    results["principle"] = principle
    summarise("Principle/Courier", principle)
    courier_id = None
    for holder in (principle or {}), ((principle or {}).get("principle") or {}):
        if isinstance(holder, dict) and holder.get("courierId"):
            courier_id = holder["courierId"]
            break
    print(f"  courierId: {'found' if courier_id else 'NOT FOUND — check principle.json'}")

    if courier_id:
        districts = call("GET", f"{API}CourierDistrict/StreetList/Courier/{courier_id}", token)
        results["districts"] = districts
        summarise("CourierDistrict/StreetList/Courier/{id}", districts)

        # Find the district the user cares about, by any field that carries its code.
        target = None
        for item in districts if isinstance(districts, list) else []:
            blob = json.dumps(item, ensure_ascii=False)
            if args.district in blob:
                target = item
                break
        if target is None:
            print(f"  district {args.district} not found; see districts.json for the available ones")
        else:
            district_id = target.get("id") or target.get("districtId")
            print(f"  district {args.district} -> id {district_id}")
            if district_id:
                for label, url in [
                    # This one backs the Looplijst popup: every distribution order
                    # for the courier, each with its addresses.
                    ("distribution_order_districts", f"{API}DistributionOrderDistricts"),
                    # The full address list of the district (the Stratenlijst button).
                    ("street_list", f"{API}District/{district_id}/StreetList"),
                    ("walkdates", f"{API}districts/walkdates?districtId={district_id}&courierId={courier_id}"),
                ]:
                    try:
                        value = call("GET", url, token)
                    except ApiError as err:
                        print(f"  {label}: failed ({err.status})")
                        results[label] = {"_error": str(err)}
                        continue
                    results[label] = value
                    summarise(label, value)

    print()
    for name, payload in results.items():
        path = write(args.out, f"{name}.json", payload, full=args.full)
        print(f"wrote {path}")
    print(
        "\nTokens are redacted in these files."
        + ("" if args.full else " Lists are sampled; re-run with --full for everything.")
        + "\nThey still contain real addresses, so treat them as personal data."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
