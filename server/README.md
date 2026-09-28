# Wijkloper server

Small FastAPI + SQLite service that holds the family's paper route and the kids'
delivery runs. In production it runs as a Docker container on the Lightsail
instance, behind the Caddy reverse proxy that already serves the other sites.
Caddy terminates TLS (Let's Encrypt, renewed automatically) and forwards
`https://wijkloper.aeromech.co` to the container on the shared Docker network.

## Hosting on the Lightsail box (what is set up)

All commands run in the Lightsail browser terminal as `ubuntu`.

1. **Code**: the GitHub repo is cloned at `~/wijkloper`. The server has a
   read-only deploy key (`~/.ssh/wijkloper_deploy`) registered on the repo.
2. **Settings**: `~/wijkloper/server/.env` (not in git) holds
   `WIJKLOPER_FAMILY_NAME`, `WIJKLOPER_PAIRING_CODE`, `WIJKLOPER_PARENT_PIN`,
   `WIJKLOPER_ENABLE_DOCS`, `WIJKLOPER_TZ` and `PROXY_NETWORK=aeromechui_default`.
   Code and PIN are only read on the very first start; afterwards they live in
   the database and are changed from the app (Parent mode › Settings).
3. **Container**: `cd ~/wijkloper/server && docker compose up -d --build` builds
   the image and starts the `wijkloper` container on the `aeromechui_default`
   network. The database lives in the named volume `server_wijkloper-data`.
4. **Proxy**: `/home/ubuntu/AeroMechUI/Caddyfile` has the block

   ```
   wijkloper.aeromech.co {
           reverse_proxy wijkloper:8000
   }
   ```

   After editing that file: `docker exec aeromechui-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`.

Useful commands:

```bash
cd ~/wijkloper/server
docker compose ps                    # should say "Up ... (healthy)"
docker compose logs --tail 50 -f     # live API log
docker compose exec wijkloper python -m app.cli show        # family name, pairing code, counts
docker compose exec wijkloper python -m app.cli set-pin 4321
docker compose exec wijkloper python -m app.cli set-code 24681357
docker compose exec wijkloper python -m app.cli imports     # history of route imports
docker logs --tail 30 aeromechui-caddy-1                     # certificate / proxy log
```

## Importing a delivery list from the distributor

`python -m app.cli import-route <file.json> [--dry-run] [--force]` reconciles the
route with a normalised delivery list (see [../tools/README.md](../tools/README.md)
for where that list comes from). The payload names the products it covers, and
the importer only adds or removes assignments for those products inside the
streets the list mentions, so a single-paper list can never wipe another round.
Houses that disappear keep their address row and any note; they just stop being
delivered.

Safety rail: if a list would stop more than a quarter of the delivered houses
*and* more than eight of them, the run is refused and recorded rather than
applied, on the assumption that the source is broken. `--force` overrides it.
Every run is written to the `imports` table, visible with `app.cli imports`.

Map the distributor's product names to yours with the `import_product_map`
setting, e.g. `{"Barneveldse Krant": "Barnevelder"}`.

### Nightly import from the spread-it portal

Add the four `SPREADIT_*` values to `~/wijkloper/server/.env` (see
`.env.example`), restart the container, and tell the importer how the
distributor's paper maps to yours:

```bash
docker compose exec wijkloper python -m app.cli map-product "Barneveldse Krant" Barnevelder
```

Check what it would do before trusting it:

```bash
docker compose exec wijkloper python -m app.cli sync-spreadit --dry-run
```

Then schedule it with `crontab -e`:

```
45 5 * * * cd /home/ubuntu/wijkloper/server && /usr/bin/docker compose exec -T wijkloper python -m app.cli sync-spreadit >> /home/ubuntu/wijkloper-sync.log 2>&1
```

Keep `WIJKLOPER_IMPORT_TIME` in `.env` in step with that line (05:45 here): the
phones expect a successful run by that time plus 15 minutes, and show a warning
on the home screen when a morning is missed or fails.

To see whether it is running: Parent mode → *Portal import* shows the last
check, the last run that changed anything and the log of recent attempts;
`curl -s https://wijkloper.aeromech.co/api/health` reports `last_import_at`;
and `docker compose exec wijkloper python -m app.cli imports` lists every
attempt, failed ones included.

`SPREADIT_PRODUCTS` limits the import to named products. That matters: the feed
also contains weekly advertising leaflets whose names change every week, and the
unaddressed door-to-door copies carry no house list at all. Rounds you maintain
by hand, such as De Week and the folders, are never touched.

Houses that only subscribe on some weekdays (the Saturday-only ones) are
detected by comparing the most recent order for each weekday, and are stored as
a per-address day override, exactly as if a parent had set it in the app.

## Updating the server

On the PC: commit and push. On the server:

```bash
cd ~/wijkloper && git pull && cd server && docker compose up -d --build
```

The data volume is untouched by updates.

## Backup

The whole state is one SQLite file inside the volume:

```bash
docker compose exec wijkloper python -c "import sqlite3; sqlite3.connect('/data/wijkloper.db').backup(sqlite3.connect('/data/backup.db'))"
docker cp wijkloper:/data/backup.db ~/wijkloper-backup-$(date +%F).db
```

## Security notes

* Only Caddy is reachable from the internet; the API port 8000 is not published.
* Every request except `/api/health` and `/api/pair` needs a device token that a
  phone obtains once with the family pairing code. Parent actions need a 12-hour
  parent token obtained with the PIN.
* Wrong pairing codes and PINs are slowed down (1 s) and locked out per IP after
  5 failures for 15 minutes. Prefer an 8-digit pairing code.
* `WIJKLOPER_ENABLE_DOCS=0` hides the interactive API docs.
* A phone can be revoked in Parent mode › Settings › Paired phones.

## Home-network alternative (Raspberry Pi, plain http)

`sudo bash install.sh` installs the API as a systemd service on port 8000 with
data in `/var/lib/wijkloper`. `sudo bash install.sh --domain example.org`
additionally installs Caddy on the host for HTTPS. In the app choose "Use a
different server" › "Search on this Wi-Fi".

## Run locally (Windows) for development

```powershell
cd server
python -m venv .venv
.venv\Scripts\pip install -r requirements-dev.txt
$env:WIJKLOPER_DATA_DIR = "$PWD\data"; $env:WIJKLOPER_PAIRING_CODE = "123456"
.venv\Scripts\python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

Tests: `.venv\Scripts\python -m pytest -q`

## How access works

| Step | Who | What |
| --- | --- | --- |
| `POST /api/pair` | any phone | sends the family pairing code, receives a device token |
| `Authorization: Bearer <token>` | paired phone | read config, upload runs, read stats |
| `POST /api/parent/login` | parent | sends the PIN, receives a 12-hour parent token |
| `X-Parent-Token` | parent | everything under `/api/admin/*` |

Kids' phones never see the PIN; it is only checked on the server.

## Data model in one breath

Kids deliver a **route**, which is an ordered list of **streets**, each with
**addresses** (house numbers). **Products** are the things delivered
(Barnevelder, Folders, De Week) and each has the weekdays it appears on. An
address is linked to the products it receives; a link can override the days
(e.g. a house that only gets the Barnevelder on Saturday). **Extras** are
one-off deliveries: a product goes to a list of addresses on one specific date
(`/api/admin/extras`; phones receive upcoming ones in the config). Finished
**runs** store the time, the number of stops and how many of each paper were
delivered.

Default number ordering per street: `asc`, `desc`, `odd_up_even_back`,
`even_up_odd_back`, `odd_then_even`, `even_then_odd` or `custom`.
