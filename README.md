# Nepal Revenue Intelligence

A responsive, Supabase-backed revenue monitoring application for Nepal's fiscal-year reporting. The frontend is hosted on GitHub Pages; authentication, data storage, classification rules and reporting functions run in Supabase.

## Deployment

1. In Supabase SQL Editor, run migrations in order:
   - `supabase/migrations/001_initial_schema.sql`
   - `supabase/migrations/002_revenue_rules_dashboard.sql`
2. In Supabase Authentication, enable Email/Password. To use Google sign-in, enable Google as an OAuth provider and configure the Google client ID/secret and the Supabase callback URL in Google Cloud.
3. Add the deployed GitHub Pages URL to Supabase Authentication URL Configuration (Site URL and allowed redirect URLs).
4. Create or sign in with `rohanbjkr@gmail.com`. Promote the account to administrator with the SQL below.
5. Import the authoritative Bikram Sambat fiscal calendar from the Data Operations page. Required CSV columns: `gregorian_date,nepali_date,fiscal_year,fiscal_month,fiscal_day`. The fiscal month convention is 1 = Shrawan through 12 = Ashadh.
6. Upload the daily revenue CSV. Required columns: `COLLECTION_DATE,REVENUE_HEAD_ID,REVENUE_DESC,COLLECTION_AMOUNT`; dates must be ISO `YYYY-MM-DD`.

### First administrator

After the user has registered or signed in once, run:

```sql
insert into public.profiles(id, display_name, email, role)
select id, 'System Administrator', email, 'admin'
from auth.users
where lower(email) = lower('rohanbjkr@gmail.com')
on conflict (id) do update
set role = 'admin', email = excluded.email;
```

Newly registered users are provisioned as viewers. Administrators can promote users to editor or administrator in User Administration.

## Classification policy

The editable `revenue_classification_rules` table is seeded by migration 002. The longest matching active code prefix wins. Omitted codes remain in the raw database but are excluded from classified aggregates. Prefixes 3311 and 3313 are omitted to avoid double counting VAT and excise collection accounts. Administrators can add, edit, enable or disable rules in the application.

## Targets

Monthly formula: previous fiscal year's same-month actual collection × (1 + growth assumption / 100). Manual monthly target overrides are preserved when the formula is regenerated. Annual targets are stored separately.

## Data integrity and access

- Revenue records are unique on `(collection_date,revenue_head_id)`.
- CSV import uses a database RPC and rejects existing date/code duplicates. It creates missing revenue-head metadata using the CSV description but does not overwrite existing descriptions.
- Raw observations are retained. Classification exclusions affect reporting only.
- Viewer: read dashboards and revenue heads. Editor: import data and manage targets. Admin: manage classification rules, users, fiscal calendar and audit records.
- The browser contains only the Supabase publishable key. Never put a service-role key in GitHub Pages or client-side code.

## Before official use

The current CSV supplied for development is hypothetical test data. The dashboard labels it as test data. Replace it with approved source data and load a complete, authoritative BS fiscal calendar. Test user roles, RLS policies, backup/restore, data correction and dashboard totals against official statements before relying on it for policy decisions. No calendar dates are invented by the application.
