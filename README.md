# Government Revenue Intelligence Dashboard (Nepal)
Static GitHub Pages frontend with Supabase PostgreSQL and Auth.
## Setup
1. Create a Supabase project and run `supabase/migrations/001_initial_schema.sql` in SQL Editor.
2. Create an Auth user. Promote first administrator with:
`insert into public.profiles(id,display_name,role) select id,'System Administrator','admin' from auth.users where email='YOUR_EMAIL';`
3. Put the project URL and publishable key in CONFIG in index.html. Use only a publishable key in browser code; never expose secret/service-role keys.
4. Import the revenue classification, then a complete official Gregorian-to-Bikram-Sambat fiscal calendar into fiscal_calendar. Required fields: gregorian_date, nepali_date, fiscal_year, fiscal_month (1 Shrawan to 12 Ashadh), fiscal_day.
5. Upload revenue CSV with COLLECTION_DATE, REVENUE_HEAD_ID, REVENUE_DESC, COLLECTION_AMOUNT. Revenue codes must exist in revenue_heads.
## Monthly target rule
Target for each fiscal month = previous fiscal year's same-month actual * (1 + x/100). Formula-generated targets retain manual overrides.
## Data integrity
Unique key is (collection_date,revenue_head_id). The import RPC inserts new records only and rejects duplicates. Use audited correction workflows for approved historical corrections.
## Current limitations
The UI is scaffolded. Historical data, official revenue classification and exact BS calendar have to be loaded before live figures are meaningful. Review RLS and test role accounts before official use. The initial importer requires all revenue codes to be seeded first.
