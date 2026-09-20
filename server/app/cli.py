"""Small maintenance CLI, run on the server as the service user or in the container.

    python -m app.cli show                    # family name, pairing code, devices, DB path
    python -m app.cli set-pin 4321            # reset the parent PIN
    python -m app.cli set-code 246810         # change the pairing code
    python -m app.cli set-family "Familie Barker"
    python -m app.cli import-route list.json  # apply a delivery list (--dry-run, --force)
    python -m app.cli imports                 # recent import runs
"""
from __future__ import annotations

import json
import sys

from .db import connect, db_path, get_setting, hash_secret, init_db, set_setting


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__)
        return 0
    init_db()
    db = connect()
    try:
        command = argv[0]
        if command == "show":
            devices = db.execute("SELECT COUNT(*) AS n FROM devices").fetchone()["n"]
            kids = db.execute("SELECT COUNT(*) AS n FROM kids WHERE archived=0").fetchone()["n"]
            addresses = db.execute("SELECT COUNT(*) AS n FROM addresses").fetchone()["n"]
            runs = db.execute("SELECT COUNT(*) AS n FROM runs").fetchone()["n"]
            print("Database:       ", db_path())
            print("Family name:    ", get_setting(db, "family_name"))
            print("Pairing code:   ", get_setting(db, "pairing_code"))
            print("Parent PIN:      (hashed; default 1234 unless changed)")
            print("Config version: ", get_setting(db, "config_version"))
            print("Paired devices: ", devices)
            print("Kids / addresses / runs: %s / %s / %s" % (kids, addresses, runs))
            return 0
        if command == "set-pin" and len(argv) == 2:
            set_setting(db, "parent_pin_hash", hash_secret(argv[1].strip()))
            db.commit()
            print("Parent PIN updated.")
            return 0
        if command == "set-code" and len(argv) == 2:
            set_setting(db, "pairing_code", argv[1].strip())
            db.commit()
            print("Pairing code updated.")
            return 0
        if command == "set-family" and len(argv) == 2:
            set_setting(db, "family_name", argv[1].strip())
            db.commit()
            print("Family name updated.")
            return 0
        if command == "import-route" and len(argv) >= 2:
            from .importer import ImportError_, apply_import

            path = argv[1]
            dry_run = "--dry-run" in argv
            force = "--force" in argv
            try:
                with open(path, encoding="utf-8") as handle:
                    payload = json.load(handle)
            except (OSError, ValueError) as err:
                print(f"Cannot read {path}: {err}", file=sys.stderr)
                return 2
            try:
                report = apply_import(db, payload, dry_run=dry_run, force=force)
            except ImportError_ as err:
                print(f"Import refused: {err}", file=sys.stderr)
                return 1
            counts = report["counts"]
            print(
                f"{'Would apply' if dry_run else ('Applied' if report['applied'] else 'Not applied')}: "
                f"{counts['added']} added, {counts['removed']} stopped, "
                f"{counts['new_streets']} new streets, {counts['unchanged']} unchanged"
            )
            for line in report["added"][:20]:
                print(f"  + {line}")
            for line in report["removed"][:20]:
                print(f"  - {line}")
            if not report["ok"]:
                print(report.get("error", "refused"), file=sys.stderr)
                return 1
            return 0
        if command == "imports":
            from .importer import recent_imports

            for row in recent_imports(db):
                flag = "ok " if row["ok"] else "REFUSED"
                applied = "applied" if row["applied"] else "not applied"
                print(f"{row['ran_at']}  {flag}  {applied:<11}  {row['source']}/{row['district']}  {row['summary']}")
            return 0
        print(__doc__)
        return 2
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())
