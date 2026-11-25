# Database Reference

## 1. Database platform

The current application is designed around Supabase, which provides PostgreSQL, authentication, browser-accessible APIs, row-level security and RPC functions.

The SQL files in `supabase/migrations/` are the repository's database change history. The list of files is not proof that all migrations have been applied to the live project.

## 2. Main tables

The initial schema migration creates the following core tables. Later migrations add fields and analytical functionality.

| Table | Purpose |
|---|---|
| `profiles` | Application user profile, email/display name and role |
| `fiscal_calendar` | Gregorian date to Nepali date, fiscal year, fiscal month and fiscal day mapping |
| `revenue_heads` | Revenue-head code, description, hierarchy and metadata |
| `revenue_daily` | Daily collection by date and revenue-head code |
| `revenue_classification_rules` | Prefix-based classification and omit rules |
| `annual_targets` | Annual target by fiscal year and revenue-head identifier |
| `monthly_targets` | Monthly target, previous-year actual, growth assumption and override flag |
| `upload_history` | Import file and row-count/status metadata |
| `audit_logs` | User action and entity audit records |

Later migrations introduce additional classification fields and viewer/access-code functionality. Inspect all migration files for the exact current schema before creating a new production database.

### Important constraints in the initial schema

- `fiscal_calendar.gregorian_date` is the primary key.
- Fiscal month is constrained to 1 through 12.
- `revenue_heads.code` is the primary key.
- `revenue_daily.collection_amount` is non-negative.
- `revenue_daily` has a unique constraint on (`collection_date`, `revenue_head_id`).
- Annual targets are unique by fiscal year and revenue-head identifier.
- Monthly targets are unique by fiscal year, fiscal month and revenue-head identifier.

Amounts are stored as `numeric(20,2)` in the initial schema. Do not change amount precision during migration without a documented reconciliation and approval.

## 3. Classification model

The original rule structure contains:
- `code_prefix`: numeric revenue-head prefix.
- `classification`: legacy classification label.
- `action`: `classify` or `omit`.
- `reason`, `is_active`, update metadata.

Subsequent migrations add `classification1` and `classification2`. The current treemap migration treats Classification 1 as the broad heading and Classification 2 as the detailed heading, while retaining legacy `classification` as a compatibility fallback.

Rule lookup is prefix based. The most specific active matching prefix is intended to win. During migration, preserve every prefix, active flag, action, label, reason and update metadata. Do not flatten the two classification levels into one field.

### Omit policy

An `omit` rule is a reporting exclusion. Raw source observations should remain available for audit and reconciliation. Excluded codes must not contribute to the applicable classified totals, comparisons, growth calculations or target-generation bases. Because this logic is implemented across SQL functions, test each report function rather than assuming every function applies the same filter.

## 4. User roles

The initial role model is:

| Role | Intended capability |
|---|---|
| `viewer` | Read dashboards and revenue information |
| `editor` | Import revenue data and manage targets |
| `admin` | Manage users, classification rules, calendar and administrative records |

The current repository also includes viewer access-code and lockout migrations. Their exact behavior and current frontend integration must be reviewed before production. Do not treat a browser/IP lockout as a substitute for account-level authentication, rate limiting at the server or an audited security control.

Newly registered Supabase users are provisioned as viewers according to the repository README. Role promotion is an administrative action.

## 5. Row-level security and RPC

The initial migration enables RLS on the main tables and defines policies around authenticated users and role helper functions such as:
- `current_user_role()`
- `is_editor()`
- `is_admin()`

Database functions are exposed through authenticated RPC calls where granted. The import and target-generation functions check editor permissions. Administrative functions must retain their intended role checks and grants after migration.

A plain PostgreSQL server does not automatically reproduce Supabase's `auth.uid()`, `auth.users`, `authenticated` role, PostgREST RPC routing or Supabase policy context. If moving away from Supabase, these must be replaced by an explicit application authentication/API layer and database authorization design. Do not mechanically run the Supabase migrations on an unrelated PostgreSQL server and assume the app will work.

## 6. Revenue import behavior

The import RPC in migration 002:
- Requires editor permission.
- Parses JSON rows.
- Creates missing revenue-head metadata without replacing existing descriptions.
- Inserts valid non-negative amounts.
- Uses the date/code unique constraint to ignore duplicate observations.
- Returns inserted, duplicate and invalid row counts.

The frontend also supports an original FCGO Excel layout as described in the operations manual. Excel parsing occurs in the browser before the rows are sent to the import RPC. The Excel file's `Current` column is used as the collection amount, and a user-selected collection date is applied to the rows.

## 7. Targets

The monthly target formula documented in the repository is:

`previous fiscal year's same-month actual × (1 + growth assumption / 100)`

Manual monthly target overrides are preserved when the generation function updates formula-based targets. Annual targets are stored separately. Preserve the override flag and formula inputs during migration.

## 8. Database migration procedure

1. Obtain written approval and provision the destination database.
2. Take a full source database backup using an authorized database administrator.
3. Record source database version, extensions, schemas, tables, indexes, sequences, functions, triggers, policies, grants and row counts.
4. Compare live source schema with the GitHub migration history. Identify migrations already applied and any live-only changes.
5. Restore schema and data into a staging database, or create the schema by applying reviewed migrations in order.
6. Recreate authentication and authorization according to the approved destination architecture.
7. Migrate data in dependency order: users/profiles as supported, calendar, revenue heads, classification rules, daily revenue, targets, upload history and audit records. Preserve keys and relationships where applicable.
8. Recreate indexes, functions, triggers, grants and security policies.
9. Run reconciliation queries and dashboard acceptance tests.
10. Freeze source writes, perform final incremental synchronization, validate and cut over.

Do not migrate password hashes or authentication internals into a different identity platform unless the platform explicitly supports that process and it has been security-reviewed.

## 9. Minimum reconciliation

Record source and destination counts and totals for:
- Revenue rows by date and fiscal year.
- Distinct revenue-head codes.
- Sum of collection amounts by day, month and fiscal year.
- Duplicate date/code keys.
- Calendar dates and fiscal-year assignments.
- Classification rules by action and level.
- Annual and monthly targets, including manual overrides.
- Profiles by role, without exposing passwords or secrets.
- Upload and audit history.

All financial totals should reconcile exactly at the stored precision unless an approved transformation is documented.
