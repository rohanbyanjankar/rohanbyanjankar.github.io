#!/usr/bin/env python3
"""Fetch the official FCGO daily report through its JSON API."""
import csv
import json
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests

API_URL = "https://dailybudgetary.fcgo.gov.np/api/report"
OUT = Path("data/fcgo-latest.json")
CALENDAR = Path("data/fiscal_calendar.csv")
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; RevenueIntelligence/1.0)", "Accept": "application/json"}


def reporting_date():
    # FCGO's API expects a Gregorian date. Use Nepal local time, not the
    # GitHub runner's UTC date.
    return datetime.now(ZoneInfo("Asia/Kathmandu")).date().isoformat()


def nepali_date_for(ad_date):
    with CALENDAR.open("r", encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("gregorian_date") == ad_date:
                return row.get("nepali_date", "").replace("-", "/")
    raise ValueError(f"{ad_date} is not present in {CALENDAR}")


def amount(value, field):
    try:
        result = float(value)
    except (TypeError, ValueError):
        raise ValueError(f"FCGO API field {field} is not numeric: {value!r}")
    if result < 0:
        raise ValueError(f"FCGO API field {field} is negative: {result}")
    return result


def extract(payload, ad_date, source_url):
    if not isinstance(payload, dict) or payload.get("hasData") is not True:
        raise ValueError(f"FCGO API returned no report data for {ad_date}")
    targets = payload.get("targets") or {}
    rev = payload.get("rev")
    if not isinstance(rev, list) or len(rev) < 4:
        raise ValueError("FCGO API response does not contain the four expected revenue series")

    # API series order, verified against the official report: tax, non-tax,
    # grants and other receipts. Revenue totals comprise tax + non-tax.
    tax_upto = amount(rev[0].get("upto"), "rev[0].upto")
    tax_today = amount(rev[0].get("today"), "rev[0].today")
    nontax_upto = amount(rev[1].get("upto"), "rev[1].upto")
    nontax_today = amount(rev[1].get("today"), "rev[1].today")
    grants_upto = amount(rev[2].get("upto"), "rev[2].upto")
    grants_today = amount(rev[2].get("today"), "rev[2].today")
    other_upto = amount(rev[3].get("upto"), "rev[3].upto")
    other_today = amount(rev[3].get("today"), "rev[3].today")

    tax_target = amount(targets.get("tax"), "targets.tax")
    nontax_target = amount(targets.get("nonTax"), "targets.nonTax")
    total_today = tax_today + nontax_today
    total_upto = tax_upto + nontax_upto
    total_target = tax_target + nontax_target

    return {
        "source": source_url,
        "reporting_date_bs": nepali_date_for(ad_date),
        "reporting_date_ad": ad_date,
        "fiscal_year": payload.get("fy"),
        "unit": "Lakh NPR",
        "fetched_at_utc": datetime.now(timezone.utc).isoformat(),
        "total_revenue": {
            "target_lakh": total_target,
            "up_to_yesterday_lakh": total_upto - total_today,
            "today_lakh": total_today,
            "up_to_today_lakh": total_upto,
            "achievement_percent": (total_upto / total_target * 100) if total_target else None,
        },
        "tax_revenue": {
            "target_lakh": tax_target,
            "up_to_yesterday_lakh": tax_upto - tax_today,
            "today_lakh": tax_today,
            "up_to_today_lakh": tax_upto,
            "achievement_percent": (tax_upto / tax_target * 100) if tax_target else None,
        },
        "non_tax_revenue": {
            "target_lakh": nontax_target,
            "up_to_yesterday_lakh": nontax_upto - nontax_today,
            "today_lakh": nontax_today,
            "up_to_today_lakh": nontax_upto,
            "achievement_percent": (nontax_upto / nontax_target * 100) if nontax_target else None,
        },
        "grants": {"today_lakh": grants_today, "up_to_today_lakh": grants_upto},
        "other_receipts": {"today_lakh": other_today, "up_to_today_lakh": other_upto},
    }


def main():
    ad_date = reporting_date()
    url = f"{API_URL}?date={ad_date}"
    response = requests.get(url, headers=HEADERS, timeout=(15, 45))
    response.raise_for_status()
    payload = response.json()
    result = extract(payload, ad_date, url)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if "--write" in __import__("sys").argv:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")


if __name__ == "__main__":
    main()
