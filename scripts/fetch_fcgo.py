#!/usr/bin/env python3
"""Fetch the official FCGO daily report through its JSON API."""
import csv
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

API_URL = "https://dailybudgetary.fcgo.gov.np/api/report"
OUT = Path("data/fcgo-latest.json")
CALENDAR = Path("calendar/fiscal_calendar.csv")
HEADERS = {
    "User-Agent": "Mozilla/5.0 (compatible; RevenueIntelligence/1.0)",
    "Accept": "application/json",
}

# FCGO may respond slowly or have temporary connectivity interruptions.
RETRY_POLICY = Retry(
    total=5,
    connect=5,
    read=3,
    backoff_factor=3,
    status_forcelist=(429, 500, 502, 503, 504),
    allowed_methods=("GET",),
    raise_on_status=False,
)
SESSION = requests.Session()
SESSION.mount("https://", HTTPAdapter(max_retries=RETRY_POLICY))


def reporting_date():
    # FCGO expects Gregorian date. Use Nepal local time, not runner UTC.
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
        raise ValueError("FCGO API response does not contain four revenue series")

    # The API response order is retained as separate series. Labels follow
    # the current FCGO response convention supplied for this integration.
    series = []
    for index, label in enumerate(("tax", "non_tax", "grants", "other_receipts")):
        item = rev[index]
        if not isinstance(item, dict):
            raise ValueError(f"FCGO API rev[{index}] is not an object")
        upto = amount(item.get("upto"), f"rev[{index}].upto")
        today = amount(item.get("today"), f"rev[{index}].today")
        if today > upto:
            raise ValueError(f"FCGO API {label} today exceeds cumulative amount")
        series.append({"up_to_today_lakh": upto, "today_lakh": today})

    tax_target = amount(targets.get("tax"), "targets.tax")
    nontax_target = amount(targets.get("nonTax"), "targets.nonTax")
    tax, nontax, grants, other = series
    total_today = tax["today_lakh"] + nontax["today_lakh"]
    total_upto = tax["up_to_today_lakh"] + nontax["up_to_today_lakh"]
    total_target = tax_target + nontax_target

    def metrics(target, cumulative, today):
        return {
            "target_lakh": target,
            "up_to_yesterday_lakh": cumulative - today,
            "today_lakh": today,
            "up_to_today_lakh": cumulative,
            "achievement_percent": (cumulative / target * 100) if target else None,
        }

    return {
        "source": source_url,
        "reporting_date_bs": nepali_date_for(ad_date),
        "reporting_date_ad": ad_date,
        "fiscal_year": payload.get("fy"),
        "unit": "Lakh NPR",
        "fetched_at_utc": datetime.now(timezone.utc).isoformat(),
        "total_revenue": metrics(total_target, total_upto, total_today),
        "tax_revenue": metrics(tax_target, tax["up_to_today_lakh"], tax["today_lakh"]),
        "non_tax_revenue": metrics(nontax_target, nontax["up_to_today_lakh"], nontax["today_lakh"]),
        "grants": grants,
        "other_receipts": other,
    }


def main():
    ad_date = reporting_date()
    url = f"{API_URL}?date={ad_date}"
    try:
        response = SESSION.get(url, headers=HEADERS, timeout=(30, 60))
    except requests.exceptions.RequestException as exc:
        raise SystemExit(
            "Unable to connect to the FCGO API after automatic retries. "
            "This is a network/server reachability issue, not a calendar parsing error. "
            f"Requested URL: {url}. Details: {exc}"
        ) from exc
    response.raise_for_status()
    result = extract(response.json(), ad_date, url)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if "--write" in sys.argv:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
