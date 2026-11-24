-- Repair Revenue Analytics category filters after the move to two-level classification.
-- Broad selectors use Classification 2; specific selectors use Classification 1.
-- The legacy classification column now mirrors Classification 2 and must not
-- be used to identify VAT, Excise, Income Tax, Customs duty, etc.

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

  if not exists (
    select 1 from public.fiscal_calendar
    where trim(fiscal_year) = trim(p_fiscal_year)
  ) then
    raise exception 'Fiscal year not found in fiscal calendar';
  end if;

  with selected_years as (
    select fiscal_year
    from (
      select distinct fiscal_year,
        split_part(fiscal_year, '/', 1)::integer as fy_start
      from public.fiscal_calendar
      where split_part(fiscal_year, '/', 1)::integer
        <= split_part(p_fiscal_year, '/', 1)::integer
    ) y
    order by fy_start desc
    limit 5
  ),
  base as (
    select
      c.fiscal_year,
      c.fiscal_month,
      r.collection_amount,
      lower(trim(coalesce(nullif(rule.classification1, ''), 'Unclassified'))) as class1,
      lower(trim(coalesce(nullif(rule.classification2, ''), nullif(rule.classification, ''), 'Unclassified'))) as class2,
      coalesce(rule.action, 'classify') as action
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    join selected_years sy on sy.fiscal_year = c.fiscal_year
    left join lateral (
      select classification1, classification2, classification, action
      from public.revenue_classification_rules
      where is_active
        and r.revenue_head_id like code_prefix || '%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
  ),
  filtered as (
    select *
    from base
    where action <> 'omit'
      and case
        when lower(trim(p_category)) = 'total' then true
        when lower(trim(p_category)) = 'tax revenue' then class2 = 'tax revenue'
        when lower(trim(p_category)) = 'non-tax revenue' then class2 = 'non-tax revenue'
        else class1 = lower(trim(p_category))
          or class2 = lower(trim(p_category))
      end
  ),
  month_grid as (
    select
      sy.fiscal_year,
      m.month_no,
      coalesce(sum(f.collection_amount), 0)::numeric as amount,
      count(f.collection_amount)::integer as observations
    from selected_years sy
    cross join generate_series(1, 12) m(month_no)
    left join filtered f
      on f.fiscal_year = sy.fiscal_year
     and f.fiscal_month = m.month_no
    group by sy.fiscal_year, m.month_no
  ),
  year_json as (
    select
      fiscal_year,
      jsonb_agg(
        jsonb_build_object(
          'month', month_no,
          'amount', amount,
          'observations', observations
        ) order by month_no
      ) as monthly
    from month_grid
    group by fiscal_year
  )
  select jsonb_build_object(
    'fiscal_year', p_fiscal_year,
    'category', p_category,
    'years',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object('fiscal_year', fiscal_year, 'monthly', monthly)
          order by split_part(fiscal_year, '/', 1)::integer desc
        )
        from year_json
      ),
      '[]'::jsonb
    )
  )
  into outj;

  return outj;
end;
$$;


create or replace function public.get_revenue_category_heads(
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

  with base as (
    select
      r.revenue_head_id as code,
      coalesce(h.description, r.revenue_description, r.revenue_head_id) as description,
      lower(trim(coalesce(nullif(rule.classification1, ''), 'Unclassified'))) as class1,
      lower(trim(coalesce(nullif(rule.classification2, ''), nullif(rule.classification, ''), 'Unclassified'))) as class2,
      coalesce(rule.action, 'classify') as action,
      sum(r.collection_amount)::numeric as amount
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    left join public.revenue_heads h on h.code = r.revenue_head_id
    left join lateral (
      select classification1, classification2, classification, action
      from public.revenue_classification_rules
      where is_active
        and r.revenue_head_id like code_prefix || '%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
    where trim(c.fiscal_year) = trim(p_fiscal_year)
    group by
      r.revenue_head_id, h.description, r.revenue_description,
      rule.classification1, rule.classification2, rule.classification, rule.action
  ),
  filtered as (
    select *
    from base
    where action <> 'omit'
      and amount > 0
      and case
        when lower(trim(p_category)) = 'total' then true
        when lower(trim(p_category)) = 'tax revenue' then class2 = 'tax revenue'
        when lower(trim(p_category)) = 'non-tax revenue' then class2 = 'non-tax revenue'
        else class1 = lower(trim(p_category))
          or class2 = lower(trim(p_category))
      end
  ),
  totals as (
    select sum(amount)::numeric as total_amount from filtered
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', code,
        'description', description,
        'category', initcap(class1),
        'classification1', initcap(class1),
        'classification2', initcap(class2),
        'current', amount,
        'share', case
          when coalesce((select total_amount from totals), 0) > 0
          then round(amount / (select total_amount from totals) * 100, 2)
          else 0
        end,
        'prior', 0,
        'growth', null
      )
      order by amount desc
    ),
    '[]'::jsonb
  )
  into outj
  from filtered;

  return outj;
end;
$$;

revoke all on function public.get_monthly_revenue_profile(text, text) from public, anon;
grant execute on function public.get_monthly_revenue_profile(text, text) to authenticated;
revoke all on function public.get_revenue_category_heads(text, text) from public, anon;
grant execute on function public.get_revenue_category_heads(text, text) to authenticated;
