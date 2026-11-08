# MotorMarket Daily Picks

At 9:05am Sydney on Sunday, Tuesday and Wednesday this job:
1. runs Metabase question 270 and writes each buyer's 3 picks onto their HubSpot contact (existing contacts only);
2. runs the "ending" question and rebuilds the "Ending tomorrow at 12pm" block in the email template.

The HubSpot workflow then sends the email at 12:05pm to contacts whose `mp_rec_generated_at` changed
(for the next closing day: Monday, Wednesday, Thursday).

## Schedule
The job is started by a cron-job.org job (`5 9 * * 0,2,3`, Australia/Sydney) that POSTs to
`https://api.github.com/repos/victionn/motormarket-daily-picks/actions/workflows/daily-picks.yml/dispatches`
with body `{"ref":"main","inputs":{"mode":"live"}}` and a fine-grained token (this repo only, Actions: read & write).
GitHub's built-in `schedule:` isn't used: its runs started 3-6 hours late. Token expires 8 Nov 2027.

## Settings (GitHub → Settings → Secrets and variables → Actions)
Secrets:
- `METABASE_API_KEY` – Metabase API key with access to the collection holding questions 270 and ending-today
- `HUBSPOT_TOKEN` – HubSpot service key (contacts read/write + content)

Variables:
- `MODE` – fallback mode when a run is started without a `mode` input
- `TEST_EMAILS` – comma-separated emails that get written in test mode
- `ENDING_QUESTION_ID` – Metabase question number for ending-today (leave unset to skip the template update)
- `TEMPLATE_PATH` – Design Manager path of the email template (default `motormarket-daily-picks.html`)

## Run by hand
Actions → Daily picks → Run workflow → pick a mode.
