"""Small maintenance CLI, run on the Pi as the service user or root.

    python -m app.cli show              # family name, pairing code, devices, DB path
    python -m app.cli set-pin 4321      # reset the parent PIN
    python -m app.cli set-code 246810   # change the pairing code
    python -m app.cli set-family "Familie Barker"
"""
from __future__ import annotations

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
        print(__doc__)
        return 2
    finally:
        db.close()


if __name__ == "__main__":
    sys.exit(main())
