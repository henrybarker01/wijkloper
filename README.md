# Wijkloper

A paper-route helper for the family. Kids see exactly which paper goes to which
house today, time themselves and chase personal bests; parents maintain the
streets, house numbers and papers from any phone in the family.

```
app/      Flutter app (Android)        — kids + parent mode
server/   FastAPI + SQLite service     — runs on the Raspberry Pi at home
```

## How it works

* **Papers** (Barnevelder, Folders, De Week, …) each have the weekdays they appear.
* **Streets** belong to a **route** and are walked in order; each street has
  **house numbers** with a walking order (ascending, odd side up / even side back, …).
* Every house is linked to the papers it receives. A link can deviate from the
  paper's normal days (a house that only gets the Barnevelder on Saturday).
* From that, the app computes the plan for any day: how many of each paper to
  pack, and per house what to deliver. Thursday shows coloured labels per house
  (Barnevelder + Folders, Barnevelder only, De Week); normal days just show numbers.
* Kids start the timer, tap houses as they deliver, and get a personal-best
  comparison, streak and family leaderboard when they finish.
* Phones keep a copy of the route and of finished runs, so everything works out
  on the street without Wi-Fi. Runs upload automatically when back home.

## First-time setup

1. **Server on the Pi** — see [server/README.md](server/README.md). In short:
   `scp -r server pi@<pi-ip>:~/wijkloper-server` then
   `ssh pi@<pi-ip> "sudo bash ~/wijkloper-server/install.sh"`. The script prints
   the server URL and the family pairing code. Parent PIN starts as `1234`.
2. **Install the app** on each phone: build with `flutter build apk --release`
   in `app/` and copy `app/build/app/outputs/flutter-apk/app-release.apk` to the
   phone (or `flutter install` with the phone on USB).
3. **Pair each phone**: open the app on the home Wi-Fi → *Search on this Wi-Fi* →
   enter the pairing code.
4. **Parent mode** (lock icon, PIN): add the kids, check the papers and their
   days, add streets in walking order, add house numbers (e.g. 1–60, odd/even)
   and pick what they get. Select several houses at once to give or remove a paper.

## Development

```bash
# server (Windows PowerShell)
cd server; python -m venv .venv; .venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\python -m pytest -q
$env:WIJKLOPER_DATA_DIR="$PWD\data"; $env:WIJKLOPER_PAIRING_CODE="123456"
.venv\Scripts\python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# app
cd app; flutter pub get; flutter test; flutter run
```

The Android emulator reaches a server on this PC at `http://10.0.2.2:8000`.
Real phones use the Pi's LAN address, e.g. `http://192.168.178.240:8000`.
