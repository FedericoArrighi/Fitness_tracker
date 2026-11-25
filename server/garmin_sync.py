#!/usr/bin/env python3
"""Fetches your newest data from Garmin Connect into garmin_inbox.json.

It only READS from Garmin. The app (button "Sync Garmin Connect") asks the sync
server to run this script and then imports the inbox file, the same way the
"Garmin full export" import works. You can also run it by hand:

    garmin_env\\Scripts\\python garmin_sync.py            (new data since the last run)
    garmin_env\\Scripts\\python garmin_sync.py --days 60  (the last 60 days again)
    garmin_env\\Scripts\\python garmin_sync.py --login    (log in again, with 2-factor code)

It uses the login token saved by garmin_dump.py (folder garmin_tokens). When
the token is too old, run it once with --login in a PowerShell window.
"""
import argparse
import datetime
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
INBOX = os.path.join(HERE, "garmin_inbox.json")
STATE = os.path.join(HERE, "garmin_state.json")

# Only these fields of an activity are kept (no places, names or profile data).
ACTIVITY_KEYS = (
    "activityId", "activityName", "startTimeLocal", "startTimeGMT",
    "beginTimestamp", "duration", "elapsedDuration", "movingDuration",
    "distance", "elevationGain", "elevationLoss", "minElevation",
    "maxElevation", "calories", "bmrCalories", "averageHR", "maxHR",
    "averageRunningCadenceInStepsPerMinute", "maxRunningCadenceInStepsPerMinute",
    "avgDoubleCadence", "maxDoubleCadence", "avgRunCadence", "maxRunCadence",
    "avgStrideLength", "avgVerticalOscillation", "avgVerticalRatio",
    "avgGroundContactTime", "avgPower", "maxPower", "lapCount", "totalReps",
    "activeSets", "totalSets", "steps", "vO2MaxValue", "description",
    "aerobicTrainingEffect", "anaerobicTrainingEffect",
)
LAP_SKIP = ("lengthDTOs", "connectIQMeasurement", "startLatitude", "startLongitude",
            "endLatitude", "endLongitude")
STATS_KEYS = ("calendarDate", "totalSteps", "activeKilocalories",
              "totalDistanceMeters", "floorsAscendedInMeters", "restingHeartRate")
SLEEP_KEYS = ("calendarDate", "deepSleepSeconds", "lightSleepSeconds",
              "remSleepSeconds", "awakeSleepSeconds", "sleepStartTimestampGMT",
              "sleepEndTimestampGMT")


def slim_activity(a):
    out = {k: a[k] for k in ACTIVITY_KEYS if k in a and a[k] is not None}
    t = a.get("activityType")
    if isinstance(t, dict):
        out["activityType"] = {"typeKey": t.get("typeKey")}
    return out


def slim_laps(split_data):
    laps = split_data.get("lapDTOs") if isinstance(split_data, dict) else None
    if not isinstance(laps, list):
        return []
    return [{k: v for k, v in lap.items() if k not in LAP_SKIP}
            for lap in laps if isinstance(lap, dict)]


def slim_sleep(data):
    dto = data.get("dailySleepDTO") if isinstance(data, dict) else None
    if not isinstance(dto, dict):
        return None
    if not (dto.get("deepSleepSeconds") or dto.get("lightSleepSeconds")
            or dto.get("remSleepSeconds")):
        return None  # no sleep recorded for this night
    out = {k: dto[k] for k in SLEEP_KEYS if k in dto and dto[k] is not None}
    overall = ((dto.get("sleepScores") or {}).get("overall") or {}).get("value")
    if overall is not None:
        out["sleepScores"] = {"overallScore": overall}
    return out


def slim_stats(data):
    if not isinstance(data, dict) or data.get("totalSteps") is None:
        return None
    return {k: data[k] for k in STATS_KEYS if k in data and data[k] is not None}


def login(interactive):
    if interactive:
        from garmin_dump import login as interactive_login
        return interactive_login()
    from garminconnect import Garmin
    from garmin_dump import TOKENS
    if not (os.path.isdir(TOKENS) and os.listdir(TOKENS)):
        print("LOGIN NEEDED: no saved login. Run once in PowerShell: "
              "garmin_env\\Scripts\\python garmin_sync.py --login")
        return None
    try:
        client = Garmin()
        client.login(TOKENS)
        return client
    except Exception as e:
        print("LOGIN NEEDED: the saved login does not work any more (%s). "
              "Run once in PowerShell: garmin_env\\Scripts\\python garmin_sync.py --login" % e)
        return None


def read_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def pause():
    time.sleep(0.4)  # be gentle with Garmin


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, help="fetch the last N days again")
    ap.add_argument("--login", action="store_true", help="log in again (asks for a code)")
    args = ap.parse_args()

    try:
        import garminconnect  # noqa: F401
    except ImportError:
        print("ERROR: the library garminconnect is not installed in this Python.")
        return 1
    if sys.version_info < (3, 12):
        print("ERROR: Python 3.12 or newer is needed (this is %s)." % sys.version.split()[0])
        return 1

    client = login(args.login)
    if client is None:
        return 2

    today = datetime.date.today()
    if args.days:
        start = today - datetime.timedelta(days=min(max(args.days, 1), 365))
    else:
        last = read_state().get("last_ok")
        try:
            start = datetime.date.fromisoformat(last) - datetime.timedelta(days=2)
        except (TypeError, ValueError):
            start = today - datetime.timedelta(days=14)
        # at least the last 8 days, so nothing is lost if an import was cancelled
        start = min(start, today - datetime.timedelta(days=7))
    print("Fetching from %s to %s ..." % (start, today))

    # ---- activities with their laps ----
    activities = []
    try:
        raw = client.get_activities_by_date(start.isoformat(), today.isoformat())
    except Exception as e:
        print("ERROR: could not read the activities: %s" % e)
        return 1
    for a in raw or []:
        item = slim_activity(a)
        kind = str((a.get("activityType") or {}).get("typeKey", ""))
        if a.get("activityId") and "strength" not in kind and a.get("hasSplits"):
            try:
                item["laps"] = slim_laps(client.get_activity_splits(a["activityId"]))
            except Exception as e:
                print("  laps of %s skipped: %s" % (a["activityId"], e))
            pause()
        activities.append(item)

    # ---- sleep and daily numbers ----
    days = {}
    fails = 0
    d = start
    while d <= today:
        key = d.isoformat()
        entry = {}
        try:
            sleep = slim_sleep(client.get_sleep_data(key))
            if sleep:
                entry["sleep"] = sleep
            pause()
            stats = slim_stats(client.get_stats(key))
            if stats:
                entry["stats"] = stats
            pause()
        except Exception as e:
            fails += 1
            print("  day %s skipped: %s" % (key, e))
            if fails >= 5:
                print("ERROR: too many failures, stopping.")
                return 1
        if entry:
            days[key] = entry
        d += datetime.timedelta(days=1)

    inbox = {
        "fetched_at": int(time.time() * 1000),
        "from": start.isoformat(),
        "to": today.isoformat(),
        "activities": activities,
        "days": days,
    }
    tmp = INBOX + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(inbox, f, ensure_ascii=False)
    os.replace(tmp, INBOX)
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump({"last_ok": today.isoformat()}, f)
    print("OK: %d activities, %d days saved." % (len(activities), len(days)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
