#!/usr/bin/env python3
"""Fetch and extract the official FCGO daily receipts table."""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup

URL = "https://dailybudgetary.fcgo.gov.np/"
LEGACY_URL = "https://old.fcgo.gov.np/daily-budgetary-analysis"
OUT = Path("data/fcgo-latest.json")
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; RevenueIntelligence/1.0)"}


def number(value):
    value = value.replace(",", "").replace(" ", "").strip()
    if re.search(r"[A-Za-z]", value):
        return None
    value = re.sub(r"[^0-9.()-]", "", value)
    if not value or value in {"-", "—"}:
        return None
    if value.startswith("(") and value.endswith(")"):
        value = "-" + value[1:-1]
    try:
        return float(value)
    except ValueError:
        return None


def extract(html, source_url=URL):
    soup = BeautifulSoup(html, "html.parser")
    text = " ".join(soup.stripped_strings)
    date_match = re.search(r"As of\\s+(\\d{4}-\\d{2}-\\d{2})\\s*\\((\\d{4}-\\d{2}-\\d{2})\\)", text, re.I)
    if not date_match:
        raise ValueError("Could not identify the FCGO reporting date in 'As of BS (AD)' format.")

    chosen = None
    for table in soup.find_all("table"):
        rows = table.find_all("tr")
        header_text = " ".join(cell.get_text(" ", strip=True).lower() for row in rows[:3] for cell in row.find_all(["th", "td"]))
        if "target/budget" in header_text and "up to today" in header_text and "today" in header_text:
            chosen = rows
            break
    if chosen is None:
        raise ValueError("Could not find the FCGO table with Target/Budget, Today and Up to Today columns.")

    found = {}
    for row in chosen:
        cells = [c.get_text(" ", strip=True) for c in row.find_all(["th", "td"])]
        if not cells:
            continue
        label_text = " ".join(cells[:2]).lower().replace("\\xa0", " ")
        if "tax revenue" in label_text:
            key = "tax_revenue"
        elif re.search(r"(^|\\s)revenue(\\s|$)", label_text) and "non tax" not in label_text and "tax revenue" not in label_text:
            key = "total_revenue"
        else:
            continue
        nums = [number(x) for x in cells if number(x) is not None]
        if len(nums) < 5:
            continue
        found[key] = {
            "target_lakh": nums[0],
            "up_to_yesterday_lakh": nums[1],
            "today_lakh": nums[2],
            "up_to_today_lakh": nums[3],
            "achievement_percent": nums[4],
        }

    required = {"total_revenue", "tax_revenue"}
    if not required.issubset(found):
        raise ValueError("Missing required FCGO rows: " + ", ".join(sorted(required - set(found))))

    return {
        "source": source_url,
        "reporting_date_bs": date_match.group(1),
        "reporting_date_ad": date_match.group(2),
        "unit": "Lakh NPR",
        "fetched_at_utc": datetime.now(timezone.utc).isoformat(),
        **found,
    }


def main():
    session = requests.Session()
    session.headers.update(HEADERS)
    candidates = []

    # A failure at either host must not prevent trying the other official
    # FCGO endpoint. Keep connection and read timeouts bounded.
    endpoints = [(URL, (10, 25)), (LEGACY_URL, (10, 25))]
    for endpoint, timeout in endpoints:
        try:
            response = session.get(endpoint, timeout=timeout)
            response.raise_for_status()
            response.encoding = response.apparent_encoding or response.encoding
            candidates.append((response.url, response.text))

            # The current portal may embed the legacy daily report.
            portal = BeautifulSoup(response.text, "html.parser")
            for frame in portal.find_all("iframe", src=True):
                frame_url = urljoin(response.url, frame["src"])
                if "fcgo.gov.np" not in frame_url:
                    continue
                try:
                    frame_response = session.get(frame_url, timeout=(10, 25))
                    frame_response.raise_for_status()
                    frame_response.encoding = frame_response.apparent_encoding or frame_response.encoding
                    candidates.append((frame_response.url, frame_response.text))
                except requests.RequestException as exc:
                    print(f"Embedded FCGO report unavailable ({frame_url}): {exc}", file=sys.stderr)
        except requests.RequestException as exc:
            print(f"FCGO endpoint unavailable ({endpoint}): {exc}", file=sys.stderr)

    last_error = None
    for source_url, html in candidates:
        try:
            result = extract(html, source_url=source_url)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            if "--write" in sys.argv:
                OUT.parent.mkdir(parents=True, exist_ok=True)
                OUT.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\\n", encoding="utf-8")
            return
        except ValueError as exc:
            last_error = exc

    if not candidates:
        raise RuntimeError("Both official FCGO endpoints were unreachable. No new snapshot was written.")
    raise RuntimeError(f"Fetched FCGO pages, but could not parse the daily report. Last parser error: {last_error}")


if __name__ == "__main__":
    main()
