#!/usr/bin/env python3
"""Step 1 of the Garmin sync: look at what Garmin really sends.

This script logs in to Garmin Connect (with the python-garminconnect library)
and saves a few SAMPLES as JSON files into the folder garmin_dump (next to
this file). It only READS; it changes nothing at Garmin and nothing in your
app or in sync.db.

Needs Python 3.12 or newer and the library:
    py -3.13 -m venv garmin_env
    garmin_env\\Scripts\\python -m pip install --upgrade garminconnect curl_cffi
Run it (from the server folder):
    garmin_env\\Scripts\\python garmin_dump.py

The first run asks for your Garmin e-mail, password and (if you use it) the
two-factor code. The password is NOT saved. Garmin gives the library a login
token, which is saved in the folder garmin_tokens: treat that folder like a
password (never share it, never put it in a zip). Later runs use the token.

Before the samples are saved, places (GPS), names and profile data are
removed. Still, have a quick look at the files before you send them to anyone.
"""
import datetime
import getpass
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOKENS = os.path.join(HERE, "garmin_tokens")
OUT = os.path.join(HERE, "garmin_dump")

# keys that contain one of these words are removed from the samples
PRIVATE = (
    "latitude", "longitude", "locationname", "owner", "profile", "displayname",
    "fullname", "email", "image", "username", "userid", "deviceid",
)


def scrub(x):
    """A copy of x without places, names and profile data."""
    if isinstance(x, dict):
        return {
            k: scrub(v)
            for k, v in x.items()
            if not any(p in str(k).lower() for p in PRIVATE)
        }
    if isinstance(x, list):
        return [scrub(v) for v in x]
    return x


def save(name, data):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(scrub(data), f, indent=1, ensure_ascii=False, default=str)
    print("  saved", name)


def ask_mfa():
    return input("Garmin two-factor code: ").strip()


def login():
    from garminconnect import Garmin

    # 1) the saved token (no password needed)
    if os.path.isdir(TOKENS) and os.listdir(TOKENS):
        try:
            client = Garmin()
            client.login(TOKENS)
            print("Logged in with the saved token.")
            return client
        except Exception as e:  # token too old or rejected: log in again
            print("The saved token did not work (%s). Logging in again." % e)

    # 2) e-mail and password (asked here, never saved)
    email = os.environ.get("GARMIN_EMAIL") or input("Garmin e-mail: ").strip()
    password = os.environ.get("GARMIN_PASSWORD") or getpass.getpass(
        "Garmin password (nothing is shown while you type): "
    )
    client = Garmin(email, password, prompt_mfa=ask_mfa)
    client.login(TOKENS)
    print("Logged in.")
    return client


def attempt(label, fn, *args):
    """Calls fn; returns the result or None (the error is saved as a note)."""
    try:
        return fn(*args)
    except Exception as e:
        print("  %s failed: %s" % (label, e))
        save("error_%s.json" % label.replace(" ", "_"), {"error": str(e)})
        return None


def main():
    try:
        import garminconnect
    except ImportError:
        print("The library is missing. Install it first:")
        print("  python -m pip install --upgrade garminconnect curl_cffi")
        return 1
    print("Python", sys.version.split()[0], "- garminconnect",
          getattr(garminconnect, "__version__", "(version unknown)"))
    if sys.version_info < (3, 12):
        print("This library needs Python 3.12 or newer. Use the newer Python.")
        return 1

    try:
        client = login()
    except Exception as e:
        print("Login failed:", e)
        print("Send me this text (without your password) and I will help.")
        return 1

    today = datetime.date.today()
    week_ago = today - datetime.timedelta(days=7)

    print("Activities of the last 7 days ...")
    acts = attempt(
        "activities", client.get_activities_by_date,
        week_ago.isoformat(), today.isoformat(),
    )
    if acts:
        save("activities_list.json", acts)
        # the laps of the newest activity that is not a gym session
        for a in acts:
            kind = str((a.get("activityType") or {}).get("typeKey", ""))
            if kind and "strength" not in kind and a.get("activityId"):
                splits = attempt("splits", client.get_activity_splits, a["activityId"])
                if splits:
                    save("activity_splits_%s.json" % kind, splits)
                break

    print("Sleep and daily numbers of the last 3 days ...")
    for back in (1, 2, 3):
        day = (today - datetime.timedelta(days=back)).isoformat()
        sleep = attempt("sleep " + day, client.get_sleep_data, day)
        if sleep:
            save("sleep_%s.json" % day, sleep)
        stats = attempt("stats " + day, client.get_stats, day)
        if stats:
            save("stats_%s.json" % day, stats)

    print("\nDone. The samples are in:", OUT)
    print("Look at them in Notepad. If they look fine, send me these files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
