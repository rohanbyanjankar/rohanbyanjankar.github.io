# System Architecture

## 1. Current logical architecture

The current implementation is a browser-based application. The frontend is in `index.html`; PostgreSQL data, authentication, row-level security (RLS), database functions and reporting calculations are provided through Supabase.

```text
User browser
   |
   | HTTPS: static application
   v
GitHub Pages
   |
   | Supabase client requests (publishable/anon key)
   v
Supabase project
   |-- Authentication
   |-- PostgreSQL tables
   |-- RLS policies
   |-- SQL functions / RPC endpoints
   |
   +-- Revenue records, targets, rules, calendar, audit records

GitHub Actions
   |-- FCGO fetch workflow --> data/fcgo-latest.json --> GitHub Pages
   |-- Calendar workflow --> validate source --> generated calendar files
```

This is a logical view of the repository design, not a network-security diagram. The exact live Supabase project settings and current database state must be checked by an authorized administrator.

## 2. Main components

### Frontend
- Main application entry point: `index.html`.
- Hosted currently as a GitHub Pages static site.
- Uses a browser Supabase client for authenticated data access.
- Includes dashboard, data operations and administration interfaces.
- The frontend contains no trusted server-side secret. A publishable/anon key may be present in browser code; it must rely on correctly configured RLS and restricted RPC permissions.

### Database and backend
- SQL migration files are in `supabase/migrations/`.
- PostgreSQL stores revenue observations, revenue-head metadata, fiscal calendar, targets, classification rules, profiles, upload history and audit logs.
- SQL functions perform imports, target generation and reporting aggregation.
- Authentication and authorization are currently designed around Supabase Auth and the `profiles` table.

### FCGO data feed
- Fetcher: `scripts/fetch_fcgo.py`.
- Workflow: `.github/workflows/fcgo-sync.yml`.
- Output path: `data/fcgo-latest.json`.
- The dashboard reads the published JSON snapshot. This feed is separate from the historical `revenue_daily` database import process.

### Fiscal calendar
- Authoritative calendar source/output path: `calendar/fiscal_calendar.csv`.
- Generator: `calendar_engine/generate_calendar.py`.
- Workflow: `.github/workflows/update-nepali-calendar.yml`.
- The generator requires official source provenance and explicit verification before publishing calendar years.

## 3. Data flow

### Historical revenue data
1. An authorized editor or administrator selects the collection date and uploads a supported revenue file in Data Operations.
2. The frontend parses and validates the file.
3. The import RPC writes valid rows to PostgreSQL.
4. A unique constraint on collection date and revenue-head code prevents duplicate observations.
5. Reporting functions join observations to the fiscal calendar and apply active classification rules.
6. Dashboard views display totals, trends, comparisons, targets and analytical indicators.

The precise UI validation rules should be confirmed against the current frontend before production operations. The database import function is the final persistence boundary.

### Classification and reporting
- Classification rules use numeric code prefixes.
- The most specific active prefix is intended to take precedence.
- Rules with action `omit` are retained as raw observations but excluded from classified reporting calculations where the relevant SQL function applies the exclusion.
- Current code supports two-level classification fields (`classification1` and `classification2`) while retaining a legacy `classification` field for compatibility.
- Individual report functions must be reviewed to confirm consistent handling of both levels and omit rules.

### FCGO snapshot
The Python fetcher requests the report for the Nepal-local current Gregorian date, maps that date to the BS date using `calendar/fiscal_calendar.csv`, and writes a JSON snapshot. GitHub Actions attempts to commit the changed snapshot every 15 minutes.

### Fiscal calendar
Official input JSON files are validated by the generator. The workflow runs tests and publishes generated CSV/JSON outputs when the event is not a pull request. The calendar is then imported into the application through Data Operations.

## 4. Proposed MoF architecture

For official deployment, use an MoF-approved application environment and a government-controlled PostgreSQL service. The Ministry's IT team should decide whether the application is integrated into `data.mof.gov.np`, exposed under an approved path/subdomain, or linked as a separate application.

Recommended logical arrangement:

```text
MoF data portal / approved application URL
   |
   v
Government application host
   |-- Frontend
   |-- Server-side API (if required by chosen architecture)
   |-- Scheduled integration worker
   |
   v
Government PostgreSQL
   |-- Application data
   |-- Database roles and policies
   |-- Audit trail
   |
   +-- Backup and recovery service
```

A static frontend can be hosted separately from PostgreSQL, but the browser must never receive a database superuser credential or privileged service key. If the current Supabase-specific client calls are retained, an approved compatible backend/API layer is needed. A move to plain PostgreSQL alone does not automatically provide Supabase Auth, PostgREST APIs, RPC exposure or Supabase RLS identity functions.

## 5. Architecture decisions requiring MoF approval

- Government hosting provider and data-centre location.
- Whether Supabase services may be used at all, or whether the system must be fully self-hosted.
- Authentication provider and identity lifecycle.
- Network access to the FCGO API.
- Domain, TLS certificates, firewall and reverse proxy.
- Backup retention, recovery objectives and audit requirements.
- Public versus restricted information and access roles.
