# FCGO Integration

## 1. Purpose

The current integration fetches the daily report JSON from the FCGO daily budgetary reporting service and publishes a snapshot for the Revenue Intelligence frontend.

Endpoint pattern:

`https://dailybudgetary.fcgo.gov.np/api/report?date=YYYY-MM-DD`

The query date is Gregorian. The fetcher uses Nepal local time (`Asia/Kathmandu`) to determine the reporting date.

## 2. Repository implementation

- Client: `scripts/fetch_fcgo.py`
- Workflow: `.github/workflows/fcgo-sync.yml`
- Output: `data/fcgo-latest.json`
- Schedule: every 15 minutes, plus manual workflow dispatch.
- Runtime: GitHub-hosted Ubuntu runner, Python 3.12.
- HTTP dependency: `requests`.
- Retry configuration: retries connection/read errors and HTTP 429/500/502/503/504 responses.

The fetcher reads `calendar/fiscal_calendar.csv` to map the Gregorian report date to the Nepali date. It fails if the date is not found in that file.

## 3. Current output fields

The generated JSON contains:
- Source URL
- Reporting date in BS and AD
- Fiscal year
- Unit: `Lakh NPR`
- Fetch timestamp in UTC
- Total revenue metrics
- Tax revenue metrics
- Non-tax revenue metrics
- Separate grants series
- Separate other-receipts series

Each metric includes target, up-to-yesterday amount, today's amount, cumulative amount and achievement percentage where applicable.

The current code calculates total revenue as tax plus non-tax revenue. Grants and other receipts are not included in that total.

## 4. API series mapping: validation required

The current code maps the four `rev` array entries by position to:
1. tax
2. non-tax
3. grants
4. other receipts

This mapping follows the response convention supplied during implementation. It has not been independently verified against authoritative FCGO API documentation or all report variants. Before official use, MoF/FCGO should confirm the meaning and ordering of each series and the units of all fields. Store that confirmation in the project record.

## 5. Known connectivity issue

The GitHub-hosted runner has repeatedly failed to establish a TLS connection to `dailybudgetary.fcgo.gov.np:443`, including after automatic retries. This is a network reachability issue from the GitHub runner environment. It is not evidence that the API endpoint is universally unavailable.

Consequently:
- The current GitHub Actions schedule should not be treated as a reliable live feed.
- A previously committed `data/fcgo-latest.json` may be stale.
- Always inspect `reporting_date_ad` and `fetched_at_utc` before displaying the snapshot as current.

## 6. Recommended MoF deployment

Run the fetcher as a scheduled service on a government-approved host that has confirmed network access to the FCGO endpoint. Before enabling production:
1. Test DNS and HTTPS connectivity from the proposed host.
2. Test multiple reporting dates, including a date with no report.
3. Confirm the API series labels and units with FCGO.
4. Confirm how holidays, weekends and delayed reports are represented.
5. Add structured logs, timeout handling, alerting and retry limits.
6. Write snapshots atomically and retain prior snapshots for audit.
7. Expose the snapshot through the approved application/API path.
8. Monitor freshness and suppress or visibly mark stale data.

Do not assume that a Nepal-based server will necessarily reach the endpoint. Test from the exact proposed hosting network.

## 7. Data governance

The FCGO snapshot is an external-source comparison feed. It should not silently overwrite historical daily observations in `revenue_daily`. Any reconciliation or import from FCGO into the main database requires a separately approved data policy and a clear audit trail.
