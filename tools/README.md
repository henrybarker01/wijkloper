# Tools: importing the route from the spread-it courier portal

The distributor's portal at <https://bezorger.spread-it.nl> is an Angular app on
top of a JSON API. That means the walking list ("Looplijst") can be fetched
directly, with no browser automation and no screen scraping.

## The API, as used by the portal itself

Base: `https://api.spread-it.nl/api/`

| Purpose | Call |
| --- | --- |
| Log in | `POST auth/basic?anonymous=true` body `{username, password, application: 1}` → `{accessToken, refreshToken}` |
| Refresh | `GET auth/refresh` with `Authorization: Bearer <refreshToken>` |
| Who am I | `GET Principle/Courier` → principle incl. `courierId` |
| Wijken cards | `GET CourierDistrict/StreetList/Courier/{courierId}` |
| Looplijst | `GET courierdistrict/{districtId}/StreetList` |
| Bezorgdagen | `GET districts/walkdates?districtId=…&courierId=…` |

The popup's data model is a list of `distributionOrderDistricts`, each with a
`distributionOrder.distributionDate`, a `subscriptionQuantity` and
`distributionOrderAddresses`. The portal groups those by date to build the
"Bezorgdag" dropdown.

Avoid `POST courierdistrict/{id}/StreetList/Document/title/{title}` — that is the
orange download button and it generates a document server-side.

## Credentials

Your portal password stays on your machine:

```powershell
cd tools
copy .env.example .env
notepad .env
```

`tools/.env` and `tools/out/` are git-ignored. Nothing in this repo contains the
password, and the probe never prints it.

## Probing the API (read-only)

```bash
python tools/spreadit_probe.py --district 3772-013
```

It logs in **once** (a wrong password fails fast rather than retrying, so the
account cannot be locked out), then performs only GET requests, and writes
`tools/out/*.json`. Access tokens are stripped from those files and long lists
are sampled, so the output shows the structure without copying every subscriber.
Add `--full` when you want the complete data.

The output still contains real names and addresses of subscribers. Treat it as
personal data: keep it local, and trim it before sharing.

## Notes on being a good citizen

* Fetch once a day at most, at a quiet hour.
* The requests identify themselves with a `wijkloper-probe` user agent.
* This pulls only your own route data, from your own account, to save retyping
  it into Wijkloper. Check the portal's terms if you are unsure whether that is
  fine for your account.
