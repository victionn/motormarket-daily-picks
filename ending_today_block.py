"""Builds the "Ending <day> at 12pm" HTML block for the MotorMarket Daily Picks email template
and puts it between the ENDING_TODAY_START / ENDING_TODAY_END markers.

The daily script calls build_block() with the rows of the Metabase "ending today" question
(rank, vehicle, state, odometer, point_1..3, link, image) and then uploads the template.
The same list goes to every recipient, so no contact properties are needed.

Run directly to rebuild the local template from a "~"/"^" string (testing only):
    python3 ending_today_block.py motormarket-daily-picks.html cars.txt
"""
import datetime as dt
import html
import re
import sys
from zoneinfo import ZoneInfo

START = "<!-- ENDING_TODAY_START -->"
END = "<!-- ENDING_TODAY_END -->"
UTM = "?utm_source=hubspot&utm_medium=email&utm_campaign=daily_picks&utm_content=ending_today"


def _features(tags):
    """Green-tick feature lines, one per row."""
    return "".join(
        f'<div style="line-height:22px; color:#217AFF; font-weight:600;">&#10003; {html.escape(t)}</div>'
        for t in tags[:3])


def _car(c):
    """c: dict with contract_id, name, image, odometer, state, tags (list)."""
    link = html.escape(f"https://app.motorplatform.com.au/motor-market/buying/{c['contract_id']}/summary{UTM}")
    name = html.escape(c["name"])
    img = ""
    if c.get("image"):
        img = (f'<td class="col-img" width="96" valign="top" style="width:96px; padding:0 10px;">'
               f'<table role="presentation" width="96" cellpadding="0" cellspacing="0" border="0"><tr>'
               f'<td align="center" valign="middle" width="96" height="96" bgcolor="#F7F7FA" '
               f'style="width:96px; height:96px; background:#F7F7FA; border-radius:6px; font-size:0; line-height:0;">'
               f'<a href="{link}" target="_blank"><img src="{html.escape(c["image"])}" width="72" alt="{name}" '
               f'style="display:block; margin:0 auto; width:auto; height:auto; max-width:96px; max-height:96px; '
               f'border-radius:4px;"></a></td></tr></table></td>')
    meta = " &nbsp;&nbsp; ".join(x for x in (
        f"&#9201;&nbsp;{html.escape(c['odometer'])} KM" if c.get("odometer") else "",
        f"&#8982;&nbsp;{html.escape(c['state'])}" if c.get("state") else "") if x)
    closes = (f'<div style="margin:2px 0 0; line-height:20px; color:#001B49; font-size:13px; font-weight:600;">'
              f'{html.escape(c["closes"])}</div>') if c.get("closes") else ""
    feats = _features(c.get("tags") or [])
    feat_div = f'<div style="margin:6px 0 0; font-size:13px;">{feats}</div>' if feats else ""
    return f'''
          <tr>
            <td bgcolor="#ffffff" style="padding:8px 10px;">
              <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  {img}
                  <td valign="top" style="padding:2px 10px; font-family:Poppins, Arial, sans-serif; font-size:14px; color:#001B49;">
                    <a href="{link}" target="_blank" style="color:#001128; font-weight:600; text-decoration:none; line-height:20px;">{name}</a>
                    <div style="margin:4px 0 0; line-height:20px; color:#001B49; font-size:13px;">{meta}</div>
                    {feat_div}
                    <div style="margin:8px 0 0;"><a href="{link}" target="_blank" style="color:#217AFF; font-weight:600; text-decoration:none; font-size:14px;">View &amp; bid &rarr;</a></div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr><td bgcolor="#ffffff" style="padding:0 20px;"><div style="border-top:1px solid #EBF2FF; font-size:0; line-height:0;">&nbsp;</div></td></tr>'''


def _day_label(close_date, today=None):
    """'today' / 'tomorrow' / weekday name for the closing date (Sydney)."""
    today = today or dt.datetime.now(ZoneInfo("Australia/Sydney")).date()
    if not close_date:
        return "tomorrow"
    days = (close_date - today).days
    if days <= 0:
        return "today"
    if days == 1:
        return "tomorrow"
    return close_date.strftime("%A")


def build_block(cars, max_cars=10, today=None, countdown=""):
    """cars: list of dicts in rank order. Returns the HTML between the markers ('' hides the section)."""
    cars = cars[:max_cars]
    if not cars:
        return ""
    day = _day_label(cars[0].get("close_date"), today)
    head = f'''
          <tr>
            <td bgcolor="#ffffff" style="padding:28px 20px 4px; font-family:Poppins, Arial, sans-serif; font-size:18px; font-weight:600; color:#001B49;">Ending {day} at 12pm</td>
          </tr>
          <tr>
            <td bgcolor="#ffffff" style="padding:0 20px 8px; font-family:Poppins, Arial, sans-serif; font-size:14px; color:#001B49; line-height:175%;">The most-watched cars closing {day}. Get your bids in before noon.</td>
          </tr>'''
    if countdown:
        head += f'''
          <tr>
            <td bgcolor="#ffffff" align="center" style="padding:6px 20px 14px; font-size:0; line-height:0;">
              <img src="{html.escape(countdown)}" width="400" alt="Time left to bid" style="display:block; margin:0 auto; width:400px; max-width:100%; height:auto;">
            </td>
          </tr>'''
    return head + "".join(_car(c) for c in cars) + "\n          "


def insert_block(template_src, block):
    pattern = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    if not pattern.search(template_src):
        raise ValueError("ENDING_TODAY markers not found in template")
    return pattern.sub(lambda m: START + block + END, template_src, count=1)


def _closes_label(value):
    """'2026-10-30T12:00:00...' (Sydney time) -> 'Closes Fri 30 Oct, 12pm'."""
    try:
        t = dt.datetime.fromisoformat(str(value)[:19])
    except (TypeError, ValueError):
        return ""
    hour = t.strftime("%I").lstrip("0") or "12"
    time = f"{hour}{t.strftime('%p').lower()}" if t.minute == 0 else f"{hour}:{t.minute:02d}{t.strftime('%p').lower()}"
    return f"Closes {t.strftime('%a')} {t.day} {t.strftime('%b')}, {time}"


def _parse_datetime(value):
    """'2026-10-30T12:00:00...' (Sydney wall time) -> aware datetime in Sydney, or None."""
    try:
        return dt.datetime.fromisoformat(str(value)[:19]).replace(tzinfo=ZoneInfo("Australia/Sydney"))
    except (TypeError, ValueError):
        return None


def countdown_url(template, close_at):
    """Fill a countdown-image URL template with the closing time.
    Placeholders: {END_UNIX} (seconds), {END_ISO_UTC} (2026-10-30T01:00:00Z), {END_SYD} (2026-10-30 12:00)."""
    if not template or not close_at:
        return ""
    utc = close_at.astimezone(dt.timezone.utc)
    return (template.replace("{END_UNIX}", str(int(utc.timestamp())))
                    .replace("{END_ISO_UTC}", utc.strftime("%Y-%m-%dT%H:%M:%SZ"))
                    .replace("{END_SYD}", close_at.strftime("%Y-%m-%d %H:%M")))


def _parse_date(value):
    """'2026-10-30T12:00:00...' (already Sydney time) -> date, or None."""
    try:
        return dt.date.fromisoformat(str(value)[:10])
    except (TypeError, ValueError):
        return None


def cars_from_metabase(rows):
    """Rows of the Metabase "ending today" question (JSON export) -> car dicts, in rank order."""
    cars = []
    for r in rows:
        if not r.get("contract_id"):
            continue
        cars.append({
            "contract_id": r["contract_id"],
            "name": r.get("vehicle") or "",
            "image": r.get("image") or "",
            "odometer": r.get("odometer") or "",
            "state": r.get("state") or "",
            "tags": [r.get(f"point_{i}") for i in (1, 2, 3) if r.get(f"point_{i}")],
            "close_date": _parse_date(r.get("ends_at_sydney")),
            "closes": _closes_label(r.get("ends_at_sydney")),
            "close_at": _parse_datetime(r.get("ends_at_sydney")),
        })
    return cars


DATE_START = "<!-- CLOSE_DATE_START -->"
DATE_END = "<!-- CLOSE_DATE_END -->"


def close_date_text(close_date):
    """date -> 'Friday 30 October at 12pm AEDT' (AEST outside daylight saving)."""
    tz = dt.datetime(close_date.year, close_date.month, close_date.day, 12,
                     tzinfo=ZoneInfo("Australia/Sydney")).tzname()
    return f"{close_date.strftime('%A')} {close_date.day} {close_date.strftime('%B')} at 12pm {tz}"


def insert_close_date(template_src, close_date):
    """Fill the banner's 'Bidding closes ...' date. Leaves the template alone if the markers are missing."""
    if not close_date or DATE_START not in template_src:
        return template_src
    pattern = re.compile(re.escape(DATE_START) + r".*?" + re.escape(DATE_END), re.S)
    return pattern.sub(lambda m: DATE_START + html.escape(close_date_text(close_date)) + DATE_END,
                       template_src, count=1)


def parse_delimited(raw):
    """'id^name^image^odo^state^tag|tag~...' ('-' = empty) -> list of car dicts."""
    cars = []
    for row in raw.strip().split("~"):
        f = row.split("^")
        if len(f) < 6:
            continue
        clean = lambda v: "" if v == "-" else v
        cars.append({"contract_id": f[0], "name": f[1], "image": clean(f[2]), "odometer": clean(f[3]),
                     "state": clean(f[4]), "tags": [t for t in clean(f[5]).split("|") if t]})
    return cars


if __name__ == "__main__":
    tpl_path, data_path = sys.argv[1], sys.argv[2]
    src = open(tpl_path).read()
    cars = parse_delimited(open(data_path).read())
    open(tpl_path, "w").write(insert_block(src, build_block(cars)))
    print(f"inserted {len(cars[:10])} cars")
