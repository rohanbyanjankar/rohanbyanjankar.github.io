# Operations Manual

This document is for authorized Revenue Intelligence operators. Screen labels and exact workflow details should be checked against the deployed application version before training users.

## 1. User roles

- Viewer: read-only dashboard access.
- Editor: data import and target-management responsibilities.
- Administrator: user administration, classification rules, fiscal calendar and audit/administrative functions.

Assign the least privilege necessary. Do not share administrator accounts.

## 2. Daily revenue data

### Standard CSV format

The database import format uses these columns:

| Column | Meaning | Example |
|---|---|---|
| `COLLECTION_DATE` | Gregorian collection date, ISO format | `2026-11-24` |
| `REVENUE_HEAD_ID` | Revenue-head code | `11111` |
| `REVENUE_DESC` | Revenue-head description | Nepali description |
| `COLLECTION_AMOUNT` | Amount collected | `10804222` |

Dates in the standard CSV must be `YYYY-MM-DD`. Amounts must be numeric and non-negative.

### Original FCGO Excel report

The frontend has been updated to accept original FCGO Excel files with columns:

`SNo | Id | Name | Previous | Current | Total`

The `Name` field combines the revenue code and description, for example `11111-एकलौटीफर्म तथा व्यक्तिगत आयमा लाग्ने कर`. The code and description are separated from this field. The `Current` value is used as the collection amount. The operator selects one collection date in the dashboard, and that date is applied to the imported rows.

Before importing:
1. Confirm the reporting date with the source report.
2. Confirm that the correct file and date are selected.
3. Review the parsed preview.
4. Review valid, invalid and duplicate row counts.
5. Resolve unexpected parsing or duplicate issues before import.
6. Import only after the preview is consistent with the official report.
7. Retain the original source file according to MoF records policy.

### Duplicate protection

The database unique key is `(collection_date, revenue_head_id)`. Existing observations should not be replaced by an ordinary import. A duplicate should be investigated rather than silently overwritten.

A correction to an already imported observation should follow an approved correction procedure with an audit trail. Do not delete or alter source records informally.

## 3. Classification rule administration

Classification rules use revenue-head code prefixes. The longest matching active prefix is intended to take precedence over a broader prefix.

When creating or editing a rule:
- Verify the code prefix against an authoritative revenue-head list.
- Set Classification 1 to the broad heading.
- Set Classification 2 to the detailed heading.
- Choose the correct action: classify or omit.
- Record a clear reason.
- Check for overlapping prefixes and their precedence.
- Test the result in the relevant dashboard and analytical views.

An `omit` rule excludes the code from applicable classified calculations. It does not delete the raw daily observation. Confirm that the relevant SQL functions apply the omit rule before relying on an analytical output.

## 4. Targets

### Annual targets
Annual targets are stored by fiscal year and revenue-head identifier. The repository's initial documentation identifies total revenue, tax revenue, VAT, income tax and customs duty as examples of annual target headings. Confirm the live target catalogue and the current UI before entering official targets.

### Monthly targets
The documented formula is:

`previous fiscal year's same-month actual × (1 + growth assumption / 100)`

Manual monthly overrides are designed to be preserved when formula-based targets are regenerated. Check the override status before regenerating targets.

Never overwrite approved annual or monthly targets without authorization and a record of the change.

## 5. Fiscal calendar

The calendar maps Gregorian dates to:
- Nepali date
- Fiscal year
- Fiscal month (1 = Shrawan through 12 = Ashadh)
- Fiscal day (counted from Shrawan 1)

The current source path is `calendar/fiscal_calendar.csv`. The calendar generator only publishes years marked `official_verified` with provenance. See [Fiscal Calendar](FISCAL_CALENDAR.md).

Before importing a new calendar:
1. Check the calendar status JSON.
2. Confirm that each year is officially sourced and independently reviewed.
3. Review continuity and fiscal-year assignment.
4. Compare against existing database dates.
5. Resolve conflicts rather than overwriting existing rows.

## 6. FCGO comparison

The FCGO comparison page reads `data/fcgo-latest.json` and compares the snapshot with the application's daily revenue data. It is separate from the historical CSV/Excel import.

The fetcher currently treats API values as lakh NPR and computes total revenue as tax plus non-tax revenue. Grants and other receipts are retained separately. Confirm these definitions with the official FCGO reporting convention before official publication.

The GitHub Actions runner has failed to connect to the FCGO endpoint. Do not assume that the 15-minute schedule is delivering current data. Check the workflow run and the snapshot's reporting date/fetched timestamp. A stale snapshot must be labelled or suppressed.

## 7. Routine checks

At the start of each working day:
- Check the latest revenue collection date in the dashboard.
- Check the fiscal year and reporting date.
- Check whether the FCGO snapshot is current.
- Check upload history for failed or partial imports.
- Review any unexpected duplicate or invalid rows.
- Compare key totals with the official source statement.

Periodically:
- Review user accounts and roles.
- Review classification rules and omit actions.
- Reconcile revenue totals to official records.
- Verify backup completion and conduct a restore test.
- Review application errors and access logs.

## 8. Incident handling

If totals are incorrect, data are missing, the dashboard is unavailable or an unauthorized change is suspected:
1. Preserve logs, source files and screenshots.
2. Record the time, affected date range, user and observed issue.
3. Do not make repeated imports or destructive corrections.
4. Notify the system administrator and responsible MoF data owner.
5. Compare source data, import history, database records and classification rules.
6. Correct only through an approved, logged procedure.
7. Re-run reconciliation and record the resolution.
