# Nepali Fiscal Calendar

## 1. Purpose and convention

The fiscal calendar maps Gregorian dates to Bikram Sambat dates and Nepal fiscal-year dimensions.

- Fiscal year begins on Shrawan 1 and ends on the final day of Ashadh.
- Fiscal month 1 is Shrawan and fiscal month 12 is Ashadh.
- Fiscal day is counted from Shrawan 1 and may reach 366.
- Fiscal-year labels follow the application convention, for example `2083/84`.

## 2. Files

| Path | Purpose |
|---|---|
| `calendar_engine/generate_calendar.py` | Validates official input and generates outputs |
| `calendar_engine/data/official_calendar/` | One JSON input per verified BS year |
| `calendar_engine/data/legacy_unverified.csv` | Historical reference only, not automatically trusted |
| `calendar/fiscal_calendar.csv` | Generated five-column CSV for application import and FCGO date mapping |
| `calendar/fiscal_calendar.json` | Generated calendar records and provenance |
| `calendar/calendar_status.json` | Verification status and output metadata |
| `.github/workflows/update-nepali-calendar.yml` | Automated validation, tests and publication |

## 3. Accuracy policy

The generator does not infer or project unpublished BS month lengths. A year is published only when:
- Its Gregorian Baisakh 1 date is supplied.
- All 12 BS month lengths are supplied.
- The input status is exactly `official_verified`.
- Source name and source URL are recorded.
- Reviewer and verification date are recorded.
- Consecutive year anchors and date continuity pass validation.

The example values in the input README are illustrative only and must not be used as calendar data.

## 4. Input schema

Each input is named `<BS_YEAR>.json` and includes:
- `bs_year`
- `baisakh_1_gregorian` in YYYY-MM-DD format
- `month_lengths`: 12 integers in Baisakh-to-Chaitra order
- `status`: `official_verified`
- `source_name` and `source_url`
- `verified_by` and `verified_on`

A second reviewer should independently check every source year before it is marked verified.

## 5. Automation

The GitHub Actions workflow:
- Runs when calendar-engine inputs or code change.
- Runs monthly and can be manually dispatched.
- Executes `python calendar_engine/generate_calendar.py`.
- Runs unit tests with `python -m unittest discover -s calendar_engine/tests -v`.
- Commits generated `calendar/` outputs for non-pull-request events when they change.

This automates validation and publication. It does not discover authoritative calendar values by scraping or infer dates that have not been verified.

## 6. Current repository status

At the time this documentation was prepared, `calendar/calendar_status.json` reports:
- `status`: `no_verified_calendar`
- `verified_bs_years`: empty
- `verified_year_count`: 0
- `row_count`: 0
- `legacy_unverified_row_count`: 3040

Therefore, do not treat the currently present legacy calendar CSV as a verified production calendar until the official input files have been supplied, reviewed, generated and imported.

## 7. Import to the application

The generated CSV follows the five-column import format:

`gregorian_date,nepali_date,fiscal_year,fiscal_month,fiscal_day`

The application is designed to check continuity and existing dates, block conflicts and insert missing dates rather than silently overwriting existing calendar rows. Test this behavior against a staging database before production.
