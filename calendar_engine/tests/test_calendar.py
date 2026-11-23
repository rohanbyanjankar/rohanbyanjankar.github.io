import json
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path
from generate_calendar import CalendarError, build_rows, load_years, write_outputs

LENGTHS = [30, 31, 31, 32, 31, 30, 30, 29, 30, 30, 31, 30]

def write_year(folder, year, start, status="official_verified", lengths=None):
    payload = {
        "bs_year": year,
        "baisakh_1_gregorian": start.isoformat(),
        "month_lengths": lengths or LENGTHS,
        "status": status,
        "source_name": "Unit-test fixture",
        "source_url": "https://example.invalid/calendar",
        "verified_by": "Unit test",
        "verified_on": "2026-01-01",
    }
    (folder / f"{year}.json").write_text(json.dumps(payload), encoding="utf-8")

class CalendarTests(unittest.TestCase):
    def test_fiscal_start_and_partial_latest_fiscal_year(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_year(folder, 2082, date(2025, 4, 14))
            write_year(folder, 2083, date(2026, 4, 14))
            rows = build_rows(load_years(folder))
            first = next(x for x in rows if x["nepali_date"] == "2082-04-01")
            self.assertEqual((first["fiscal_year"], first["fiscal_month"], first["fiscal_day"]),
                             ("2082/83", 1, 1))
            last = rows[-1]
            self.assertEqual(last["nepali_date"], "2083-12-30")
            self.assertEqual(last["fiscal_year"], "2083/84")
            self.assertEqual(last["fiscal_day"], 273)

    def test_rejects_provisional_year(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_year(folder, 2084, date(2027, 4, 14), status="provisional")
            with self.assertRaises(CalendarError):
                load_years(folder)

    def test_rejects_missing_year(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_year(folder, 2082, date(2025, 4, 14))
            write_year(folder, 2084, date(2027, 4, 14))
            with self.assertRaises(CalendarError):
                load_years(folder)

    def test_rejects_wrong_next_year_anchor(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            write_year(folder, 2082, date(2025, 4, 14))
            write_year(folder, 2083, date(2026, 4, 13))
            with self.assertRaises(CalendarError):
                load_years(folder)

    def test_empty_source_does_not_create_projected_dates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "official"
            source.mkdir()
            years = load_years(source)
            rows = build_rows(years)
            meta = write_outputs(rows, years, root / "out")
            self.assertEqual(meta["status"], "no_verified_calendar")
            self.assertEqual(meta["row_count"], 0)
            csv = (root / "out" / "fiscal_calendar.csv").read_text().strip()
            self.assertEqual(csv, "gregorian_date,nepali_date,fiscal_year,fiscal_month,fiscal_day")

if __name__ == "__main__":
    unittest.main()
