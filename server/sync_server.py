#!/usr/bin/env python3
"""Sync server for Macro Tracker. Uses only the Python standard library.

Start it with:    python sync_server.py
Other port:       python sync_server.py --port 9000

On the first start it creates an access token and saves it in token.txt
(next to this file). Enter the server address and this token in the app.
The data is kept in sync.db (a normal SQLite file; back it up if you like).

How it works: every device sends the records it changed and receives the
records other devices changed. If two devices changed the same record, the
newer one (by its updated_at time) wins.
"""
import argparse
import json
import os
import secrets
import shutil
import sqlite3
import subprocess
import sys
import threading
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DB_PATH = os.environ.get("MT_DB", os.path.join(HERE, "sync.db"))
TOKEN_FILE = os.path.join(HERE, "token.txt")
ALLOWED_TABLES = {
    "foods",
    "log_entries",
    "recipes",
    "weights",
    "targets",
    "daily_metrics",
    "workouts",
    "user_items",
}
MAX_BODY = 200 * 1024 * 1024
LOCK = threading.Lock()

# Garmin Connect sync (optional): the app asks this server to run
# garmin_sync.py (with the Python of its own environment), which writes
# garmin_inbox.json; the app then downloads that file.
INBOX_PATH = os.path.join(HERE, "garmin_inbox.json")
GARMIN_SCRIPT = os.path.join(HERE, "garmin_sync.py")
GARMIN_LOCK = threading.Lock()
GARMIN_PYTHON = os.path.join(
    HERE, "garmin_env", "Scripts" if os.name == "nt" else "bin",
    "python.exe" if os.name == "nt" else "python",
)


def init_db():
    with closing(sqlite3.connect(DB_PATH)) as db:
        db.execute(
            "CREATE TABLE IF NOT EXISTS records ("
            " tbl TEXT NOT NULL, id TEXT NOT NULL, updated_at INTEGER NOT NULL,"
            " deleted INTEGER NOT NULL, data TEXT NOT NULL,"
            " seq INTEGER NOT NULL, origin TEXT NOT NULL,"
            " PRIMARY KEY (tbl, id))"
        )
        db.execute("CREATE INDEX IF NOT EXISTS records_seq ON records(seq)")
        db.commit()


def load_token():
    env = os.environ.get("MT_TOKEN")
    if env:
        return env.strip()
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE, encoding="utf-8") as f:
            t = f.read().strip()
            if t:
                return t
    t = secrets.token_urlsafe(24)
    with open(TOKEN_FILE, "w", encoding="utf-8") as f:
        f.write(t + "\n")
    return t


TOKEN = ""


def current_seq(db):
    return db.execute("SELECT COALESCE(MAX(seq), 0) FROM records").fetchone()[0]


def valid(r):
    return (
        isinstance(r, dict)
        and r.get("tbl") in ALLOWED_TABLES
        and isinstance(r.get("id"), str)
        and r["id"] != ""
        and isinstance(r.get("updated_at"), int)
        and not isinstance(r.get("updated_at"), bool)
        and isinstance(r.get("data"), dict)
    )


def do_sync(payload):
    client = str(payload.get("client", ""))
    since = int(payload.get("since", 0))
    records = payload.get("records", [])
    if not isinstance(records, list):
        records = []
    with closing(sqlite3.connect(DB_PATH)) as db:
        seq = current_seq(db)
        accepted = 0
        for r in records:
            if not valid(r):
                continue
            row = db.execute(
                "SELECT updated_at FROM records WHERE tbl = ? AND id = ?",
                (r["tbl"], r["id"]),
            ).fetchone()
            # The newer record wins; equal or older ones are ignored.
            if row is not None and row[0] >= r["updated_at"]:
                continue
            seq += 1
            db.execute(
                "INSERT INTO records(tbl, id, updated_at, deleted, data, seq, origin)"
                " VALUES(?, ?, ?, ?, ?, ?, ?)"
                " ON CONFLICT(tbl, id) DO UPDATE SET updated_at = excluded.updated_at,"
                " deleted = excluded.deleted, data = excluded.data,"
                " seq = excluded.seq, origin = excluded.origin",
                (
                    r["tbl"],
                    r["id"],
                    r["updated_at"],
                    1 if r.get("deleted") else 0,
                    json.dumps(r["data"]),
                    seq,
                    client,
                ),
            )
            accepted += 1
        db.commit()
        out = []
        # Everything newer than the client's last sync, except what it sent itself.
        for tbl, rid, upd, deleted, data in db.execute(
            "SELECT tbl, id, updated_at, deleted, data FROM records"
            " WHERE seq > ? AND origin != ? ORDER BY seq",
            (since, client),
        ):
            out.append(
                {
                    "tbl": tbl,
                    "id": rid,
                    "updated_at": upd,
                    "deleted": bool(deleted),
                    "data": json.loads(data),
                }
            )
        return {"seq": seq, "accepted": accepted, "records": out}


class Handler(BaseHTTPRequestHandler):
    server_version = "MacroTrackerSync/1.0"

    def log_message(self, fmt, *args):
        print("%s  %s" % (self.address_string(), fmt % args))

    def _send(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        got = self.headers.get("Authorization", "")
        return secrets.compare_digest(got, "Bearer " + TOKEN)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True})
        elif self.path == "/ping":
            if not self._authorized():
                self._send(401, {"error": "wrong token"})
                return
            with LOCK, closing(sqlite3.connect(DB_PATH)) as db:
                self._send(
                    200,
                    {"ok": True, "seq": current_seq(db),
                     "tables": sorted(ALLOWED_TABLES)},
                )
        elif self.path == "/garmin/inbox":
            if not self._authorized():
                self._send(401, {"error": "wrong token"})
                return
            try:
                with open(INBOX_PATH, encoding="utf-8") as f:
                    inbox = json.load(f)
            except (OSError, ValueError):
                inbox = {"activities": [], "days": {}}
            self._send(200, inbox)
        else:
            self._send(404, {"error": "not found"})

    def _garmin_run(self):
        """Runs garmin_sync.py once and reports how it went."""
        if not os.path.exists(GARMIN_SCRIPT):
            return {"ok": False, "output": "garmin_sync.py is missing in the server folder."}
        if not (os.path.exists(GARMIN_PYTHON) or shutil.which(GARMIN_PYTHON)):
            return {"ok": False, "output": (
                "The Garmin Python environment was not found: %s\n"
                "Create it as described (py -3.13 -m venv garmin_env ...)." % GARMIN_PYTHON)}
        if not GARMIN_LOCK.acquire(blocking=False):
            return {"ok": False, "output": "A Garmin fetch is already running."}
        try:
            res = subprocess.run(
                [GARMIN_PYTHON, GARMIN_SCRIPT],
                cwd=HERE, capture_output=True, timeout=240,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            text = (res.stdout + res.stderr).decode("utf-8", errors="replace")
            return {"ok": res.returncode == 0, "output": text[-1500:].strip()}
        except subprocess.TimeoutExpired:
            return {"ok": False, "output": "The Garmin fetch took longer than 4 minutes."}
        except OSError as e:
            return {"ok": False, "output": "Could not start the Garmin fetch: %s" % e}
        finally:
            GARMIN_LOCK.release()

    def do_POST(self):
        if self.path == "/garmin/run":
            if not self._authorized():
                self._send(401, {"error": "wrong token"})
                return
            self._send(200, self._garmin_run())
            return
        if self.path != "/sync":
            self._send(404, {"error": "not found"})
            return
        if not self._authorized():
            self._send(401, {"error": "wrong token"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                self._send(400, {"error": "bad body size"})
                return
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("payload must be an object")
            with LOCK:
                result = do_sync(payload)
        except (ValueError, KeyError, TypeError) as e:
            self._send(400, {"error": str(e)})
            return
        self._send(200, result)


def main():
    global TOKEN
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--garmin-python", default=None,
                    help="python.exe of the Garmin environment (default: garmin_env next to this file)")
    args = ap.parse_args()
    if args.garmin_python:
        global GARMIN_PYTHON
        GARMIN_PYTHON = args.garmin_python
    init_db()
    TOKEN = load_token()
    print("Macro Tracker sync server")
    print("  port:   %d" % args.port)
    print("  token:  %s   (also saved in %s)" % (TOKEN, TOKEN_FILE))
    print("  data:   %s" % DB_PATH)
    print("Press Ctrl+C to stop.")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
