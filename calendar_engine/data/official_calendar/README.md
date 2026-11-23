# Official BS calendar inputs

Add one JSON file per BS year, named `<year>.json`. Only a calendar checked
against an authoritative, published Nepali calendar may be marked
`"status": "official_verified"`.

Required fields:

- `bs_year`: integer Bikram Sambat year.
- `baisakh_1_gregorian`: Gregorian date of Baisakh 1, in YYYY-MM-DD format.
- `month_lengths`: exactly 12 integers, in BS month order from Baisakh to Chaitra.
- `status`: exactly `official_verified`.
- `source_name`, `source_url`: publication and its source URL.
- `verified_by`, `verified_on`: reviewer and YYYY-MM-DD verification date.

Illustrative schema only, not usable calendar data:

```json
{
  "bs_year": 2083,
  "baisakh_1_gregorian": "YYYY-MM-DD",
  "month_lengths": [30, 31, 31, 32, 31, 30, 30, 29, 30, 30, 31, 30],
  "status": "draft",
  "source_name": "Enter the official publication",
  "source_url": "https://example.invalid",
  "verified_by": "Enter reviewer",
  "verified_on": "YYYY-MM-DD"
}
```

The generator rejects drafts, projections, missing years, inconsistent year
anchors, invalid month lengths and discontinuous dates. Never copy the
illustrative values above into a production year file.
