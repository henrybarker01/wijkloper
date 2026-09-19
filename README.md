# Wijkloper

A paper-route helper for the family. Kids see exactly which paper goes to which
house today, time themselves and chase personal bests; parents maintain the
streets, house numbers and papers from any phone in the family.

```
app/      Flutter app (Android)        — kids + parent mode
server/   FastAPI + SQLite service     — runs in Docker behind Caddy on the Lightsail box
dist/     built APKs for sharing (not in git)
```

Live server: **https://wijkloper.aeromech.co** (the app connects there by default).

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
* Phones keep a copy of the route and of finished runs, so everything works
  without a connection. Runs upload the moment the phone is online again.

## Putting it on a phone

1. Build: in `app/` run `flutter build apk --release --split-per-abi`. Use
   `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` (fits practically
   every phone from the last ~8 years; `app-release.apk` is the universal fallback).
2. Get the file onto the phone: share it via Google Drive / WhatsApp / USB, open it
   on the phone, and allow "install unknown apps" for that app when Android asks.
3. Open Wijkloper. It shows `wijkloper.aeromech.co` and the family name. Type the
   **family code** (set in `server/.env` on the server) and a name for the phone,
   tap **Pair this phone**.
4. A parent taps the lock icon, enters the **parent PIN**, and adds the kids,
   checks the papers and their weekdays, adds streets in walking order and house
   numbers (ranges like 1–60, odd/even), and picks what each house gets. Select
   several houses at once to give or remove a paper.

Updating the app later: build again, share the new APK, install over the old one.
Phone data (pairing, cached route) is kept.

## Server

See [server/README.md](server/README.md) for hosting (Docker + Caddy on the
Lightsail instance), updating, the access model and the home-network alternative.

## Development

```powershell
# server
cd server; python -m venv .venv; .venv\Scripts\pip install -r requirements-dev.txt
.venv\Scripts\python -m pytest -q
$env:WIJKLOPER_DATA_DIR="$PWD\data"; $env:WIJKLOPER_PAIRING_CODE="123456"
.venv\Scripts\python -m uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# app
cd app; flutter pub get; flutter test; flutter run
```

To point a development build at a local server use the app's "Use a different
server" option (the Android emulator reaches this PC at `http://10.0.2.2:8000`),
or build with `--dart-define=WIJKLOPER_DEFAULT_SERVER=http://10.0.2.2:8000`.
