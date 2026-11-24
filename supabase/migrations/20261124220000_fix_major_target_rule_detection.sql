-- Correct major-heading target achievement to use Classification 1 and report active rules from the database.
-- Classification 2 contains broad groups such as "Tax revenue", so it cannot
-- be used to calculate VAT, Excise, Income Tax and Customs duty separately.
create or replace function public.get_major_heading_target_achievement(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_fy text;
  v_cutoff_day integer;
  v_cutoff_month integer;
  v_out jsonb;
  v_active_rule_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select count(*)::integer into v_active_rule_count
  from public.revenue_classification_rules
  where is_active is true and coalesce(action, 'classify') <> 'omit';

  select c.fiscal_year
    into v_fy
  from public.fiscal_calendar c
  where trim(c.fiscal_year) = trim(p_fiscal_year)
  order by c.gregorian_date desc
  limit 1;

  if v_fy is null then
    return jsonb_build_object(
      'fiscal_year', p_fiscal_year,
      'cutoff_day', null,
      'active_rule_count', v_active_rule_count,
      'headings', '[]'::jsonb
    );
  end if;

  select max(c.fiscal_day), max(c.fiscal_month)
    into v_cutoff_day, v_cutoff_month
  from public.revenue_daily r
  join public.fiscal_calendar c
    on c.gregorian_date = r.collection_date
  where trim(c.fiscal_year) = trim(v_fy);

  if v_cutoff_day is null then
    return jsonb_build_object(
      'fiscal_year', v_fy,
      'cutoff_day', null,
      'headings', '[]'::jsonb
    );
  end if;

  with categories(name, sort_order) as (
    values
      ('VAT', 1),
      ('Excise', 2),
      ('Income Tax', 3),
      ('Customs duty', 4)
  ),
  actuals_raw as (
    select
      lower(trim(coalesce(nullif(rule.classification1, ''), 'Unclassified'))) as category_key,
      sum(r.collection_amount)::numeric as actual
    from public.revenue_daily r
    join public.fiscal_calendar c
      on c.gregorian_date = r.collection_date
    left join lateral (
      select rr.classification1, rr.action
      from public.revenue_classification_rules rr
      where rr.is_active
        and r.revenue_head_id like rr.code_prefix || '%'
      order by length(rr.code_prefix) desc
      limit 1
    ) rule on true
    where trim(c.fiscal_year) = trim(v_fy)
      and c.fiscal_day <= v_cutoff_day
      and coalesce(rule.action, 'classify') <> 'omit'
    group by 1
  ),
  actuals as (
    select
      case
        when category_key = 'vat' then 'VAT'
        when category_key in ('excise', 'excise duty') then 'Excise'
        when category_key in ('income tax', 'income-tax') then 'Income Tax'
        when category_key in ('customs', 'customs duty', 'custom duty') then 'Customs duty'
        else null
      end as name,
      sum(actual)::numeric as actual
    from actuals_raw
    group by 1
  ),
  targets_raw as (
    select
      lower(trim(coalesce(nullif(rule.classification1, ''), 'Unclassified'))) as category_key,
      sum(t.target_amount)::numeric as target
    from public.monthly_targets t
    left join lateral (
      select rr.classification1, rr.action
      from public.revenue_classification_rules rr
      where rr.is_active
        and t.revenue_head_id like rr.code_prefix || '%'
      order by length(rr.code_prefix) desc
      limit 1
    ) rule on true
    where trim(t.fiscal_year) = trim(v_fy)
      and t.fiscal_month <= v_cutoff_month
      and t.revenue_head_id is not null
      and coalesce(rule.action, 'classify') <> 'omit'
    group by 1
  ),
  targets as (
    select
      case
        when category_key = 'vat' then 'VAT'
        when category_key in ('excise', 'excise duty') then 'Excise'
        when category_key in ('income tax', 'income-tax') then 'Income Tax'
        when category_key in ('customs', 'customs duty', 'custom duty') then 'Customs duty'
        else null
      end as name,
      sum(target)::numeric as target
    from targets_raw
    group by 1
  )
  select jsonb_build_object(
    'fiscal_year', v_fy,
    'cutoff_day', v_cutoff_day,
    'cutoff_month', v_cutoff_month,
    'active_rule_count', v_active_rule_count,
    'headings',
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'name', c.name,
          'actual', coalesce(a.actual, 0),
          'target', coalesce(t.target, 0),
          'achievement',
            case
              when coalesce(t.target, 0) > 0
              then coalesce(a.actual, 0) / t.target * 100
              else null
            end
        )
        order by c.sort_order
      ),
      '[]'::jsonb
    )
  )
  into v_out
  from categories c
  left join actuals a on a.name = c.name
  left join targets t on t.name = c.name;

  return v_out;
end;
$$;

revoke all on function public.get_major_heading_target_achievement(text) from public, anon;
grant execute on function public.get_major_heading_target_achievement(text) to authenticated;
