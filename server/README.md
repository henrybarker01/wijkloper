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
docker logs --tail 30 aeromechui-caddy-1                     # certificate / proxy log
```

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
