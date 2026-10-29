"""MotorMarket Daily Picks – daily job.

Every weekday morning (before the 7:30am send):
  1. Runs Metabase question 270 (picks per buyer) and writes the values onto each buyer's
     HubSpot contact (only contacts that already exist; matched on email).
  2. Runs the "ending today" Metabase question and rebuilds the "Ending today at 12pm" block
     inside the HubSpot email template (same list for everyone).
The HubSpot workflow then sends the email to contacts whose mp_rec_generated_at is from today.

Modes (env MODE):
  dry-run  – fetch + build everything, write nothing (default)
  test     – write only to contacts listed in TEST_EMAILS; template IS updated
  live     – write to everyone

Env vars: METABASE_URL, METABASE_API_KEY, PICKS_QUESTION_ID (270), ENDING_QUESTION_ID,
          HUBSPOT_TOKEN, TEMPLATE_PATH (motormarket-daily-picks.html), MODE, TEST_EMAILS,
          MIN_BUYERS (abort below this, default 20)
"""
import json
import os
import sys
import time

import requests

from ending_today_block import build_block, cars_from_metabase, insert_block

HUBSPOT = "https://api.hubapi.com"

# Columns of question 270 that are written to HubSpot (the review columns are NOT).
PROPS = ["mp_rec_generated_at"] + [
    f"mp_rec_{n}_{f}" for n in (1, 2, 3)
    for f in ("vehicle", "link", "image", "odometer", "state", "feature_1", "feature_2", "feature_3")
]


def env(name, default=None, required=True):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"Missing env var {name}")
    return v


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


# ---------------------------------------------------------------- Metabase
def run_question(card_id):
    r = requests.post(f"{env('METABASE_URL').rstrip('/')}/api/card/{card_id}/query/json",
                      headers={"x-api-key": env("METABASE_API_KEY")}, timeout=300)
    r.raise_for_status()
    rows = r.json()
    if isinstance(rows, dict):  # Metabase returns an error object instead of a list on query errors
        raise RuntimeError(f"Metabase question {card_id} failed: {json.dumps(rows)[:500]}")
    return rows


# ---------------------------------------------------------------- HubSpot
def hs(method, path, **kw):
    headers = {"Authorization": f"Bearer {env('HUBSPOT_TOKEN')}"}
    if "json" in kw:
        headers["Content-Type"] = "application/json"
    for attempt in range(5):
        r = requests.request(method, HUBSPOT + path, headers=headers, timeout=60, **kw)
        if r.status_code == 429 or r.status_code >= 500:
            time.sleep(2 ** attempt)
            continue
        if r.status_code >= 400:
            raise RuntimeError(f"HubSpot {method} {path} -> {r.status_code}: {r.text[:500]}")
        return r
    raise RuntimeError(f"HubSpot {method} {path} kept failing")


def chunks(xs, n=100):
    for i in range(0, len(xs), n):
        yield xs[i:i + n]


def contact_ids_by_email(emails):
    ids = {}
    for batch in chunks(emails):
        r = hs("POST", "/crm/v3/objects/contacts/batch/read",
               json={"idProperty": "email", "properties": ["email"],
                     "inputs": [{"id": e} for e in batch]})
        for c in r.json().get("results", []):
            ids[(c["properties"].get("email") or "").lower()] = c["id"]
    return ids


def update_contacts(updates):
    for batch in chunks(updates):
        hs("POST", "/crm/v3/objects/contacts/batch/update", json={"inputs": batch})


def get_template(path):
    return hs("GET", f"/cms/v3/source-code/published/content/{path}").text


def put_template(path, source):
    hs("PUT", f"/cms/v3/source-code/published/content/{path}",
       files={"file": (os.path.basename(path), source.encode("utf-8"), "text/html")})


# ---------------------------------------------------------------- main
def main():
    mode = os.environ.get("MODE", "dry-run")
    test_emails = {e.strip().lower() for e in os.environ.get("TEST_EMAILS", "").split(",") if e.strip()}
    min_buyers = int(os.environ.get("MIN_BUYERS", "20"))
    log(f"mode={mode}")

    # 1. Picks -> contacts
    rows = run_question(env("PICKS_QUESTION_ID", "270"))
    log(f"question 270: {len(rows)} buyers")
    if len(rows) < min_buyers and mode == "live":
        sys.exit(f"Only {len(rows)} buyers (< {min_buyers}); aborting so nobody gets a thin email")

    by_email = {(r.get("Email") or "").strip().lower(): r for r in rows if r.get("Email")}
    if mode == "test":
        # test contacts get the picks of the top buyer, so the email has real data
        sample = rows[0] if rows else None
        by_email = {e: sample for e in test_emails} if sample else {}

    ids = contact_ids_by_email(list(by_email))
    missing = [e for e in by_email if e not in ids]
    updates = [{"id": ids[e], "properties": {p: ("" if r.get(p) is None else str(r.get(p))) for p in PROPS}}
               for e, r in by_email.items() if e in ids]
    log(f"contacts to update: {len(updates)}; not in HubSpot: {len(missing)}")
    if missing:
        log("not in HubSpot (skipped): " + ", ".join(sorted(missing)[:20]) + (" …" if len(missing) > 20 else ""))

    # 2. Ending today -> template (skipped when ENDING_QUESTION_ID is not set)
    ending_id = os.environ.get("ENDING_QUESTION_ID")
    new_tpl = None
    tpl_path = env("TEMPLATE_PATH", "motormarket-daily-picks.html")
    if ending_id:
        ending = cars_from_metabase(run_question(ending_id))
        log(f"ending today: {len(ending)} cars")
        new_tpl = insert_block(get_template(tpl_path), build_block(ending))
    else:
        log("ENDING_QUESTION_ID not set: template left as is")

    if mode == "dry-run":
        log("dry-run: nothing written")
        print(json.dumps(updates[:2], indent=2, ensure_ascii=False))
        return
    if new_tpl is not None:
        put_template(tpl_path, new_tpl)
        log("template updated")
    update_contacts(updates)
    log(f"updated {len(updates)} contacts – done")


if __name__ == "__main__":
    main()
