-- Monthly revenue profile by selectable major revenue category.
-- Apply after migrations 001, 002 and 003.

create or replace function public.get_monthly_revenue_profile(
  p_fiscal_year text,
  p_category text default 'Total'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  outj jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if not exists (select 1 from public.fiscal_calendar where fiscal_year = p_fiscal_year) then
    raise exception 'Fiscal year not found in fiscal calendar';
  end if;

  with selected_years as (
    select fiscal_year
    from (
      select distinct fiscal_year,
        split_part(fiscal_year, '/', 1)::integer as fy_start
      from public.fiscal_calendar
      where split_part(fiscal_year, '/', 1)::integer <= split_part(p_fiscal_year, '/', 1)::integer
    ) y
    order by fy_start desc
    limit 5
  ),
  base as (
    select c.fiscal_year, c.fiscal_month, r.collection_amount,
      coalesce(rule.classification, 'Unclassified') as category,
      coalesce(rule.action, 'classify') as action
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    join selected_years sy on sy.fiscal_year = c.fiscal_year
    left join lateral (
      select classification, action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix || '%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
  ),
  filtered as (
    select * from base
    where action <> 'omit'
      and case
        when p_category = 'Tax revenue' then category in ('VAT','Excise','Customs','Income Tax','Unclassified')
        when p_category = 'Non-tax revenue' then category in ('Interest and Dividends','Royalty')
        when p_category = 'Total' then true
        else category = p_category
      end
  ),
  month_grid as (
    select sy.fiscal_year, m.month_no,
      coalesce(sum(f.collection_amount), 0) as amount,
      count(f.collection_amount) as observations
    from selected_years sy
    cross join generate_series(1,12) as m(month_no)
    left join filtered f on f.fiscal_year = sy.fiscal_year and f.fiscal_month = m.month_no
    group by sy.fiscal_year, m.month_no
  ),
  year_json as (
    select fiscal_year,
      jsonb_agg(jsonb_build_object(
        'month', month_no,
        'amount', amount,
        'observations', observations
      ) order by month_no) as monthly
    from month_grid
    group by fiscal_year
  )
  select jsonb_build_object(
    'fiscal_year', p_fiscal_year,
    'category', p_category,
    'years', coalesce((
      select jsonb_agg(jsonb_build_object('fiscal_year', fiscal_year, 'monthly', monthly)
        order by split_part(fiscal_year, '/', 1)::integer desc)
      from year_json
    ), '[]'::jsonb)
  ) into outj;

  return outj;
end;
$$;

revoke all on function public.get_monthly_revenue_profile(text, text) from public, anon;
grant execute on function public.get_monthly_revenue_profile(text, text) to authenticated;
