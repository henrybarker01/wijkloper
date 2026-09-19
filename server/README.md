# Wijkloper server

Small FastAPI + SQLite service that holds the family's paper route and the kids'
delivery runs. Runs on a Raspberry Pi on the home network; phones sync with it
when they are on the same Wi-Fi.

## Install / update on the Pi

From this PC:

```bash
scp -r server pi@<pi-ip>:~/wijkloper-server
ssh pi@<pi-ip> "sudo bash ~/wijkloper-server/install.sh"
```

The script installs to `/opt/wijkloper`, keeps the database in
`/var/lib/wijkloper/wijkloper.db`, and registers the `wijkloper` systemd
service on port 8000. Re-run it to deploy a newer version; data is kept.

Useful commands on the Pi:

```bash
sudo wijkloper-cli show            # family name, pairing code, counts
sudo wijkloper-cli set-pin 4321    # reset the parent PIN
sudo wijkloper-cli set-code 246810 # change the pairing code
journalctl -u wijkloper -f         # live logs
sudo systemctl restart wijkloper
```

Backup: copy `/var/lib/wijkloper/wijkloper.db` somewhere safe now and then
(`sqlite3 wijkloper.db ".backup backup.db"` for a consistent copy).

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
| `POST /api/pair` | any phone on the LAN | sends the 6-digit family pairing code, receives a device token |
| `Authorization: Bearer <token>` | paired phone | read config, upload runs, read stats |
| `POST /api/parent/login` | parent | sends the PIN, receives a 12-hour parent token |
| `X-Parent-Token` | parent | everything under `/api/admin/*` |

Kids' phones never see the PIN; it is only checked on the server.

## Data model in one breath

Kids deliver a **route**, which is an ordered list of **streets**, each with
**addresses** (house numbers). **Products** are the things delivered
(Barnevelder, Folders, De Week) and each has the weekdays it appears on. An
address is linked to the products it receives; a link can override the days
(e.g. a house that only gets the Barnevelder on Saturday). Finished **runs**
store the time, the number of stops and how many of each paper were delivered.

Default number ordering per street: `asc`, `desc`, `odd_up_even_back`,
`even_up_odd_back`, `odd_then_even`, `even_then_odd` or `custom`.
