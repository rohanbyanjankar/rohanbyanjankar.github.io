# Repository Inventory

This inventory identifies the principal files and folders present in the repository at the time this documentation was prepared.

## Top-level structure

| Path | Purpose |
|---|---|
| `index.html` | Main browser application and user interface |
| `supabase/migrations/` | Ordered PostgreSQL/Supabase schema and function migrations |
| `scripts/fetch_fcgo.py` | Python client for the FCGO daily report API |
| `.github/workflows/fcgo-sync.yml` | Scheduled FCGO snapshot workflow |
| `.github/workflows/update-nepali-calendar.yml` | Calendar validation, tests and publication workflow |
| `calendar/` | Published calendar CSV/JSON and status metadata |
| `calendar_engine/` | Calendar input schema, generator, validation and tests |
| `data/revenue.csv` | Revenue CSV file stored in the repository |
| `data/fiscal_calendar.csv` | Older calendar copy; do not assume it is authoritative |
| `data/fcgo-latest.json` | Generated FCGO snapshot when successfully fetched |
| `templates/` | Data-operation templates |
| `README.md` | Project overview and initial setup notes |
| `docs/` | System and migration documentation |

## Calendar file distinction

Two calendar CSV paths exist:
- `calendar/fiscal_calendar.csv`: designated current generated calendar output and the path used by `scripts/fetch_fcgo.py`.
- `data/fiscal_calendar.csv`: an older copy present in the repository.

Use the first path for the current FCGO fetcher. Before any production import, inspect `calendar/calendar_status.json` and verify that the output is based on officially verified year inputs. The current status file reports `no_verified_calendar`, so the existence of the CSV alone is not evidence that its contents are officially verified.

## Database migrations

The repository contains the following SQL migrations, which must be reviewed and applied in the intended order in a new database:

```text
001_initial_schema.sql
002_revenue_rules_dashboard.sql
003_revenue_intelligence.sql
004_bulk_delete_revenue_rows.sql
005_dashboard_latest_observation_date.sql
006_executive_monthly_pulse.sql
007_cumulative_daily_brief.sql
008_consolidated_executive_monthly_pulse.sql
009_fix_prior_calendar_fiscal_day.sql
010_five_year_common_cutoff.sql
011_true_fiscal_ytd_daily_brief.sql
012_daily_and_cumulative_yoy.sql
013_monthly_revenue_profile_by_category.sql
014_fix_revenue_category_matching.sql
015_treemap_share_and_growth.sql
016_fix_negative_monthly_targets.sql
017_major_heading_target_achievement.sql
018_viewer_access_codes.sql
20261124100000_two_level_revenue_classification.sql
20261124143000_executive_five_year_server_aggregation.sql
20261124160000_fix_major_target_classification_level.sql
20261124170000_fix_analytics_two_level_classification.sql
20261124173000_fix_treemap_response_shape.sql
20261124180000_revenue_policy_intelligence.sql
20261124190000_import_linked_tax_analysis.sql
20261124200000_fix_policy_intelligence_fiscal_month.sql
20261124210000_five_year_major_tax_contributions.sql
20261124220000_fix_major_target_rule_detection.sql
20261124230000_revenue_concentration_hhi.sql
20261124233000_hhi_classification1.sql
20261124240000_hhi_eight_year_history.sql
20261124250000_tax_revenue_growth_decomposition.sql
20261124260000_total_revenue_growth_decomposition.sql
20261124270000_total_revenue_classification2_top8.sql
20261124280000_access_code_visibility_and_lockout.sql
20261124290000_optimize_executive_monthly_pulse.sql
20261124293000_fix_daily_revenue_category_mapping.sql
20261124294500_ensure_classification1_column.sql
20261124295500_fix_daily_pulse_rule_lookup.sql
20261125090000_fix_treemap_previous_fiscal_year.sql
20261125110000_fix_treemap_two_level_classification.sql
```

Do not assume that a migration in GitHub has already been executed against the current Supabase project. Compare the migration list with the live database before applying anything. Some migrations alter existing functions or columns and are not safe to rerun blindly without checking their contents and effects.

## Files that need special handling

- `data/revenue.csv` is a large data file. Check whether it contains test, demonstration or production data before moving it into a government environment.
- `data/fcgo-latest.json` is generated output, not a source of truth for historical daily revenue.
- Do not copy secrets from local development environments into GitHub.
- Confirm whether `templates/` contains current upload templates and document their expected columns before issuing them to users.
