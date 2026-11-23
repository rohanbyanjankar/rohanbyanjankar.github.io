#!/usr/bin/env python3
"""Generate a verified BS fiscal calendar from explicitly approved yearly data."""
from __future__ import annotations
import argparse, csv, json, os, sys
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Any

FIELDS = ["gregorian_date", "nepali_date", "fiscal_year", "fiscal_month", "fiscal_day"]

class CalendarError(ValueError):
    pass

@dataclass(frozen=True)
class BSYear:
    year: int
    new_year: date
    month_lengths: tuple[int, ...]
    source_name: str
    source_url: str
    verified_by: str
    verified_on: str

def iso_date(value: Any, label: str) -> date:
    if not isinstance(value, str):
        raise CalendarError(f"{label} must be YYYY-MM-DD")
    try:
        result = date.fromisoformat(value)
    except ValueError as exc:
        raise CalendarError(f"{label} is invalid: {value}") from exc
    if result.isoformat() != value:
        raise CalendarError(f"{label} must use YYYY-MM-DD")
    return result

def load_year(path: Path) -> BSYear:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CalendarError(f"Cannot read {path}: {exc}") from exc
    year = raw.get("bs_year")
    if type(year) is not int or not 1900 <= year <= 2200:
        raise CalendarError(f"{path}: invalid bs_year")
    if raw.get("status") != "official_verified":
        raise CalendarError(f"{path}: only official_verified years can be published")
    start = iso_date(raw.get("baisakh_1_gregorian"), f"{path}: baisakh_1_gregorian")
    lengths = raw.get("month_lengths")
    if not isinstance(lengths, list) or len(lengths) != 12:
        raise CalendarError(f"{path}: month_lengths must contain 12 integers")
    if any(type(n) is not int or not 29 <= n <= 32 for n in lengths):
        raise CalendarError(f"{path}: month lengths must be integers from 29 to 32")
    if sum(lengths) not in (365, 366):
        raise CalendarError(f"{path}: year must total 365 or 366 days")
    for key in ("source_name", "source_url", "verified_by", "verified_on"):
        if not isinstance(raw.get(key), str) or not raw[key].strip():
            raise CalendarError(f"{path}: missing provenance field {key}")
    iso_date(raw["verified_on"], f"{path}: verified_on")
    return BSYear(year, start, tuple(lengths), raw["source_name"].strip(),
                  raw["source_url"].strip(), raw["verified_by"].strip(), raw["verified_on"].strip())

def load_years(directory: Path) -> list[BSYear]:
    paths = sorted(directory.glob("*.json"))
    years = sorted((load_year(p) for p in paths), key=lambda x: x.year)
    numbers = [x.year for x in years]
    if len(numbers) != len(set(numbers)):
        raise CalendarError("Duplicate BS years")
    for left, right in zip(years, years[1:]):
        if right.year != left.year + 1:
            raise CalendarError(f"Missing BS year between {left.year} and {right.year}")
        expected = left.new_year + timedelta(days=sum(left.month_lengths))
        if right.new_year != expected:
            raise CalendarError(f"BS {right.year} Baisakh 1 mismatch: expected {expected}, got {right.new_year}")
    return years

def build_rows(years: list[BSYear]) -> list[dict[str, Any]]:
    starts: dict[int, date] = {}
    days = []
    for item in years:
        offset = 0
        for month, length in enumerate(item.month_lengths, 1):
            month_start = item.new_year + timedelta(days=offset)
            if month == 4:
                starts[item.year] = month_start
            for day in range(1, length + 1):
                days.append((month_start + timedelta(days=day - 1), item.year, month, day))
            offset += length
    rows = []
    for gregorian, year, month, day in days:
        fy_start_year = year if month >= 4 else year - 1
        fy_start = starts.get(fy_start_year)
        if fy_start is None:
            continue
        rows.append({
            "gregorian_date": gregorian.isoformat(),
            "nepali_date": f"{year:04d}-{month:02d}-{day:02d}",
            "fiscal_year": f"{fy_start_year}/{(fy_start_year + 1) % 100:02d}",
            "fiscal_month": ((month - 4) % 12) + 1,
            "fiscal_day": (gregorian - fy_start).days + 1,
        })
    rows.sort(key=lambda x: x["gregorian_date"])
    previous_date = None
    previous_fy = None
    previous_day = None
    seen = set()
    for row in rows:
        current = date.fromisoformat(row["gregorian_date"])
        if current in seen:
            raise CalendarError(f"Duplicate Gregorian date: {current}")
        seen.add(current)
        if previous_date and current != previous_date + timedelta(days=1):
            raise CalendarError(f"Gregorian date gap: {previous_date} to {current}")
        if row["fiscal_year"] == previous_fy:
            if row["fiscal_day"] != previous_day + 1:
                raise CalendarError(f"Fiscal day discontinuity on {current}")
        elif row["fiscal_day"] != 1:
            raise CalendarError(f"Fiscal year {row['fiscal_year']} does not start on fiscal day 1")
        previous_date, previous_fy, previous_day = current, row["fiscal_year"], row["fiscal_day"]
    return rows

def legacy_count(path: Path | None) -> int:
    if path is None or not path.exists():
        return 0
    with path.open(newline="", encoding="utf-8-sig") as f:
        return sum(1 for _ in csv.DictReader(f))

def write_outputs(rows, years, out_dir: Path, legacy_path: Path | None = None):
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / "fiscal_calendar.csv"
    with csv_path.with_suffix(".csv.tmp").open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    os.replace(csv_path.with_suffix(".csv.tmp"), csv_path)
    metadata = {
        "schema_version": 1,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "status": "verified" if rows else "no_verified_calendar",
        "verified_bs_years": [x.year for x in years],
        "verified_year_count": len(years),
        "row_count": len(rows),
        "first_gregorian_date": rows[0]["gregorian_date"] if rows else None,
        "last_gregorian_date": rows[-1]["gregorian_date"] if rows else None,
        "fiscal_years": sorted({x["fiscal_year"] for x in rows}),
        "legacy_unverified_row_count": legacy_count(legacy_path),
        "provenance": [{"bs_year": x.year, "source_name": x.source_name, "source_url": x.source_url,
                        "verified_by": x.verified_by, "verified_on": x.verified_on} for x in years],
        "policy": "Only official_verified years are published. Legacy rows and projections are never promoted automatically."
    }
    (out_dir / "fiscal_calendar.json").write_text(
        json.dumps({"metadata": metadata, "calendar": rows}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (out_dir / "calendar_status.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return metadata

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--official-dir", type=Path, default=Path("calendar_engine/data/official_calendar"))
    p.add_argument("--legacy-csv", type=Path, default=Path("calendar_engine/data/legacy_unverified.csv"))
    p.add_argument("--out-dir", type=Path, default=Path("calendar"))
    a = p.parse_args()
    try:
        years = load_years(a.official_dir)
        rows = build_rows(years)
        print(json.dumps(write_outputs(rows, years, a.out_dir, a.legacy_csv), indent=2))
    except CalendarError as exc:
        print(f"CALENDAR VALIDATION FAILED: {exc}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
