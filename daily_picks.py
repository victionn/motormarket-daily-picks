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
import re
import sys
import time

import requests

from ending_today_block import build_block, cars_from_metabase, countdown_url, insert_block, insert_close_date

HUBSPOT = "https://api.hubapi.com"

# Per-pick fields. Question 270 returns each buyer's top 9 (mp_rec_1..9_*); the script writes the
# best 3 the buyer hasn't been shown recently into HubSpot slots mp_rec_1..3_* (review columns never).
FIELDS = ("vehicle", "link", "image", "odometer", "state", "closes", "feature_1", "feature_2", "feature_3")
CANDIDATES = 9
HISTORY_SENDS = 3          # don't repeat a car shown in the buyer's last 3 emails
HISTORY_PROP = "mp_rec_history"
LINK_ID = re.compile(r"/buying/([0-9a-f-]{36})/", re.I)

# Brands that stay in capitals; everything else becomes Title Case ("VOLVO" -> "Volvo").
UPPER_WORDS = {"BMW", "MG", "BYD", "GWM", "LDV", "RAM", "GMC", "HSV", "FPV", "AMG", "GT", "GTI",
               "SUV", "EV", "HR-V", "CR-V", "ZR-V", "CX-3", "CX-30", "CX-5", "CX-60", "CX-8", "CX-9",
               "MX-5", "BT-50", "D-MAX", "MU-X", "C-HR", "ASX", "RAV4", "IX35", "UX", "NX", "RX", "ES",
               "IS", "GS", "LX", "GX", "XV", "WRX", "BRZ", "XC40", "XC60", "XC90", "Q2", "Q3", "Q5", "Q7",
               "Q8", "A1", "A3", "A4", "A5", "A6", "TT", "CLA", "CLE", "CLS", "GLA", "GLB", "GLC", "GLE",
               "GLS", "SLK", "SL", "EQA", "EQB", "EQC", "EQE", "EQS", "XF", "XE", "XJ", "RS", "RCZ"}
SPECIAL = {"MERCEDES-BENZ": "Mercedes-Benz", "MERCEDES-AMG": "Mercedes-AMG", "LAND": "Land",
           "ROVER": "Rover", "ALFA": "Alfa", "ROMEO": "Romeo", "IONIQ": "IONIQ"}


def nice_name(vehicle):
    """'2023 VOLVO XC60' -> 'Volvo XC60'; '2024 TOYOTA COROLLA CROSS' -> 'Toyota Corolla Cross'."""
    words = (vehicle or "").split()
    if words and words[0].isdigit():
        words = words[1:]
    out = []
    for w in words:
        u = w.upper()
        if u in SPECIAL:
            out.append(SPECIAL[u])
        elif len(u) > 1 and u[0] == "I" and u[1:].isdigit():
            out.append("i" + u[1:])  # Hyundai i30, BMW i4
        elif u in UPPER_WORDS or any(ch.isdigit() for ch in u) or len(u) <= 2:
            out.append(u)  # model codes like X5, XC60 stay as they are
        else:
            out.append("-".join(part.capitalize() for part in u.split("-")))  # T-CROSS -> T-Cross
    return " ".join(out)


def subject_line(row):
    """Personalised subject from the buyer's picks, e.g.
    'Volvo XC60, Nissan Navara & more picked for you – bidding closes soon'"""
    names = [nice_name(row.get(f"mp_rec_{n}_vehicle")) for n in (1, 2, 3)]
    names = [n for n in names if n]
    if not names:
        return "Cars picked for you on MotorMarket – bidding closes soon"
    if len(names) == 1:
        return f"{names[0]} picked for you – bidding closes soon"
    return f"{names[0]}, {names[1]} & more picked for you – bidding closes soon"


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


def contacts_by_email(emails):
    """email -> (contact id, history string) for contacts that already exist in HubSpot."""
    found = {}
    for batch in chunks(emails):
        r = hs("POST", "/crm/v3/objects/contacts/batch/read",
               json={"idProperty": "email", "properties": ["email", HISTORY_PROP],
                     "inputs": [{"id": e} for e in batch]})
        for c in r.json().get("results", []):
            props = c["properties"]
            found[(props.get("email") or "").lower()] = (c["id"], props.get(HISTORY_PROP) or "")
    return found


def car_id(row, n):
    m = LINK_ID.search(row.get(f"mp_rec_{n}_link") or "")
    return m.group(1).lower() if m else None


def choose_picks(row, history):
    """The buyer's best 3 of their top 6, skipping cars shown in their last HISTORY_SENDS emails.
    history: 'id,id,id|id,id,id|...' newest send first. Falls back to seen cars if needed so
    there are always 3. Returns (props for slots 1..3, new history string)."""
    sends = [s for s in history.split("|") if s][:HISTORY_SENDS]
    seen = {i for s in sends for i in s.split(",") if i}
    ranked = [n for n in range(1, CANDIDATES + 1) if row.get(f"mp_rec_{n}_vehicle")]
    # drop any repeat of the same car within the ranking (safety net; the query already dedupes)
    unique, ids = [], set()
    for n in ranked:
        cid = car_id(row, n)
        if cid in ids:
            continue
        ids.add(cid)
        unique.append(n)
    ranked = unique
    chosen = [n for n in ranked if car_id(row, n) not in seen][:3]
    chosen += [n for n in ranked if n not in chosen][:3 - len(chosen)]
    props = {}
    for slot in (1, 2, 3):
        src = chosen[slot - 1] if slot <= len(chosen) else None
        for f in FIELDS:
            v = row.get(f"mp_rec_{src}_{f}") if src else None
            props[f"mp_rec_{slot}_{f}"] = "" if v is None else str(v)
    today = ",".join(i for i in (car_id(row, n) for n in chosen) if i)
    new_history = "|".join(([today] + sends)[:HISTORY_SENDS])
    return props, new_history


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
        # Test contacts get one real buyer's picks, so you see exactly what that buyer would get.
        # TEST_AS picks the buyer (their email); otherwise the most active buyer.
        test_as = os.environ.get("TEST_AS", "").strip().lower()
        sample = by_email.get(test_as) if test_as else (rows[0] if rows else None)
        if test_as and sample is None:
            sys.exit(f"TEST_AS {test_as} is not in today's picks (not an active bidder?)")
        log(f"test mode: writing the picks of {sample.get('Email') if sample else 'nobody'} "
            f"to {', '.join(sorted(test_emails))}")
        by_email = {e: sample for e in test_emails} if sample else {}

    contacts = contacts_by_email(list(by_email))
    missing = [e for e in by_email if e not in contacts]
    updates, repeats_avoided = [], 0
    for e, r in by_email.items():
        if e not in contacts:
            continue
        cid, history = contacts[e]
        props, new_history = choose_picks(r, history)
        repeats_avoided += sum(1 for n in (1, 2, 3)
                               if props[f"mp_rec_{n}_link"] != (r.get(f"mp_rec_{n}_link") or ""))
        props.update({"mp_rec_generated_at": str(r.get("mp_rec_generated_at") or ""),
                      "mp_rec_subject": subject_line(props),
                      HISTORY_PROP: new_history})
        updates.append({"id": cid, "properties": props})
    log(f"picks swapped to avoid repeats: {repeats_avoided}")
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
        timer = countdown_url(os.environ.get("COUNTDOWN_URL", ""), ending[0].get("close_at") if ending else None)
        new_tpl = insert_block(get_template(tpl_path), build_block(ending, countdown=timer))
        if ending:
            new_tpl = insert_close_date(new_tpl, ending[0].get("close_date"))
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
