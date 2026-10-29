# MotorMarket Daily Picks

Every morning at 6:15am Sydney this job:
1. runs Metabase question 270 and writes each buyer's 3 picks onto their HubSpot contact (existing contacts only);
2. runs the "ending today" question and rebuilds the "Ending today at 12pm" block in the email template.

The HubSpot workflow then sends the email at 7:30am to contacts whose `mp_rec_generated_at` changed.

## Settings (GitHub → Settings → Secrets and variables → Actions)
Secrets:
- `METABASE_API_KEY` – Metabase API key with access to the collection holding questions 270 and ending-today
- `HUBSPOT_TOKEN` – HubSpot service key (contacts read/write + content)

Variables:
- `MODE` – `dry-run`, `test` or `live` (scheduled runs use this)
- `TEST_EMAILS` – comma-separated emails that get written in test mode
- `ENDING_QUESTION_ID` – Metabase question number for ending-today (leave unset to skip the template update)
- `TEMPLATE_PATH` – Design Manager path of the email template (default `motormarket-daily-picks.html`)

## Run by hand
Actions → Daily picks → Run workflow → pick a mode.
