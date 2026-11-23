# Nepali Fiscal Calendar Engine

This engine generates the calendar used by Revenue Intelligence.

## Accuracy policy

The engine does not estimate future Bikram Sambat month lengths. It publishes
only BS years whose complete 12-month lengths and Gregorian Baisakh 1 have
been entered from an authoritative published calendar and explicitly marked
`official_verified`.

The supplied `data/legacy_unverified.csv` is preserved for reference and
migration audit. It is not treated as authoritative and is never copied into
the verified output automatically.

## Fiscal-year convention

- Fiscal year starts on Shrawan 1 and ends on the final day of Ashadh.
- Fiscal month 1 = Shrawan, ..., fiscal month 12 = Ashadh.
- Fiscal day counts calendar days from Shrawan 1, including a possible day 366.
- Labels use the existing `2083/84` format.

## Add a verified BS year

1. Obtain the year's calendar from an authoritative published source.
2. Create `data/official_calendar/<BS_YEAR>.json` using the schema in that
   folder's README.
3. Enter Baisakh 1 Gregorian date and all 12 month lengths from the same source.
4. Have a second reviewer check the values against the publication.
5. Record source name, URL, reviewer and verification date.
6. Change status to `official_verified` and commit the file.

Years must be consecutive. Each next year's Baisakh 1 must equal the previous
year's Baisakh 1 plus the previous year's 12 month lengths. A failure stops
publication.

## Outputs

- `calendar/fiscal_calendar.csv`: existing five-column Supabase import format.
- `calendar/fiscal_calendar.json`: records and provenance metadata.
- `calendar/calendar_status.json`: status used by the dashboard before import.

## Local run

```bash
python calendar_engine/generate_calendar.py
python -m unittest discover -s calendar_engine/tests -v
```

The generator uses only Python's standard library.

## GitHub automation

GitHub Actions runs on official-input or engine changes, monthly, and on manual
dispatch. It validates source files, runs tests and commits generated outputs.
This automates generation and publication once official data is supplied. It
does not scrape an unverified website or infer unpublished month lengths.

## Dashboard integration

The Data Operations page checks the published status before importing. The
dashboard validates the date sequence and fiscal classification, refuses
conflicting existing dates, and inserts only missing records. Existing calendar
rows are not silently overwritten.
