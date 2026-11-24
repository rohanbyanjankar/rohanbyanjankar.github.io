-- Optimize the executive monthly pulse without changing its JSON contract.
-- Aggregate revenue once by fiscal day, then use window functions for FYTD values.
-- Classification 2 is preferred, with the legacy classification retained as fallback.

create or replace function public.get_executive_monthly_pulse(
  p_fiscal_year text,
  p_fiscal_month integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_previous_fy text;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  if p_fiscal_month is null or p_fiscal_month < 1 or p_fiscal_month > 12 then
    raise exception 'Fiscal month must be between 1 and 12';
  end if;

  v_previous_fy := public.previous_fiscal_year(p_fiscal_year);

  with month_calendar as (
    select
      c.gregorian_date,
      c.nepali_date,
      c.fiscal_day,
      row_number() over (order by c.gregorian_date)::integer as day_no
    from public.fiscal_calendar c
    where c.fiscal_year = p_fiscal_year
      and c.fiscal_month = p_fiscal_month
  ),
  classified_rows as (
    select
      c.fiscal_year,
      c.fiscal_day,
      case
        -- Check both classification levels. Classification 2 is the primary
        -- reporting level, while Classification 1 is a fallback when the
        -- more detailed label does not identify one of the four major tax heads.
        when lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%vat%'
          or lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%value added tax%'
          then 'VAT'
        when lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%excise%'
          then 'Excise'
        when lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%custom%'
          then 'Customs duty'
        when lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%income%tax%'
          or lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%direct%tax%'
          or lower(concat_ws(' ', rule.classification2, rule.classification1, rule.classification))
          like '%tax%income%'
          then 'Income Tax'
        else null
      end as category,
      r.collection_amount as amount
    from public.fiscal_calendar c
    join public.revenue_daily r
      on r.collection_date = c.gregorian_date
    left join lateral (
      select
        rr.classification,
        rr.classification2,
        rr.action
      from public.revenue_classification_rules rr
      where rr.is_active
        and r.revenue_head_id like rr.code_prefix || '%'
      order by length(rr.code_prefix) desc
      limit 1
    ) rule on true
    where c.fiscal_year in (p_fiscal_year, v_previous_fy)
      and coalesce(rule.action, 'classify') <> 'omit'
  ),
  fiscal_days as (
    select c.fiscal_year, c.fiscal_day
    from public.fiscal_calendar c
    where c.fiscal_year in (p_fiscal_year, v_previous_fy)
  ),
  categories(category, sort_order) as (
    values
      ('VAT', 1),
      ('Income Tax', 2),
      ('Customs duty', 3),
      ('Excise', 4)
  ),
  daily_totals as (
    select
      fiscal_year,
      fiscal_day,
      sum(amount)::numeric as amount
    from classified_rows
    group by fiscal_year, fiscal_day
  ),
  daily_totals_dense as (
    select
      fd.fiscal_year,
      fd.fiscal_day,
      coalesce(dt.amount, 0)::numeric as amount
    from fiscal_days fd
    left join daily_totals dt
      on dt.fiscal_year = fd.fiscal_year
     and dt.fiscal_day = fd.fiscal_day
  ),
  daily_totals_cumulative as (
    select
      fiscal_year,
      fiscal_day,
      amount,
      sum(amount) over (
        partition by fiscal_year
        order by fiscal_day
        rows between unbounded preceding and current row
      )::numeric as cumulative_amount
    from daily_totals_dense
  ),
  daily_categories as (
    select
      fiscal_year,
      fiscal_day,
      category,
      sum(amount)::numeric as amount
    from classified_rows
    where category is not null
    group by fiscal_year, fiscal_day, category
  ),
  daily_categories_dense as (
    select
      fd.fiscal_year,
      fd.fiscal_day,
      cat.category,
      coalesce(dc.amount, 0)::numeric as amount
    from fiscal_days fd
    cross join categories cat
    left join daily_categories dc
      on dc.fiscal_year = fd.fiscal_year
     and dc.fiscal_day = fd.fiscal_day
     and dc.category = cat.category
  ),
  daily_categories_cumulative as (
    select
      fiscal_year,
      fiscal_day,
      category,
      amount,
      sum(amount) over (
        partition by fiscal_year, category
        order by fiscal_day
        rows between unbounded preceding and current row
      )::numeric as cumulative_amount
    from daily_categories_dense
  ),
  day_values as (
    select
      mc.day_no,
      mc.gregorian_date,
      mc.nepali_date,
      mc.fiscal_day,
      coalesce(cur.amount, 0)::numeric as amount,
      coalesce(prior.amount, 0)::numeric as prior_amount,
      coalesce(cur.cumulative_amount, 0)::numeric as cumulative_amount,
      coalesce(prior.cumulative_amount, 0)::numeric as cumulative_prior_amount
    from month_calendar mc
    left join daily_totals_cumulative cur
      on cur.fiscal_year = p_fiscal_year
     and cur.fiscal_day = mc.fiscal_day
    left join daily_totals_cumulative prior
      on prior.fiscal_year = v_previous_fy
     and prior.fiscal_day = mc.fiscal_day
  ),
  category_values as (
    select
      mc.day_no,
      cat.category,
      cat.sort_order,
      coalesce(cur_day.amount, 0)::numeric as daily_amount,
      coalesce(prior_day.amount, 0)::numeric as prior_daily_amount,
      coalesce(cur_ytd.cumulative_amount, 0)::numeric as cumulative_amount,
      coalesce(prior_ytd.cumulative_amount, 0)::numeric as cumulative_prior_amount
    from month_calendar mc
    cross join categories cat
    left join daily_categories cur_day
      on cur_day.fiscal_year = p_fiscal_year
     and cur_day.fiscal_day = mc.fiscal_day
     and cur_day.category = cat.category
    left join daily_categories prior_day
      on prior_day.fiscal_year = v_previous_fy
     and prior_day.fiscal_day = mc.fiscal_day
     and prior_day.category = cat.category
    left join daily_categories_cumulative cur_ytd
      on cur_ytd.fiscal_year = p_fiscal_year
     and cur_ytd.fiscal_day = mc.fiscal_day
     and cur_ytd.category = cat.category
    left join daily_categories_cumulative prior_ytd
      on prior_ytd.fiscal_year = v_previous_fy
     and prior_ytd.fiscal_day = mc.fiscal_day
     and prior_ytd.category = cat.category
  ),
  category_json as (
    select
      day_no,
      jsonb_agg(
        jsonb_build_object(
          'name', category,
          'amount', cumulative_amount,
          'prior_amount', cumulative_prior_amount,
          'cumulative_yoy_growth',
            case
              when cumulative_prior_amount <> 0
                then round((cumulative_amount / cumulative_prior_amount - 1) * 100, 2)
              else null
            end,
          'daily_yoy_growth',
            case
              when prior_daily_amount <> 0
                then round((daily_amount / prior_daily_amount - 1) * 100, 2)
              else null
            end
        )
        order by sort_order
      ) as categories
    from category_values
    group by day_no
  )
  select jsonb_build_object(
    'fiscal_year', p_fiscal_year,
    'previous_fiscal_year', v_previous_fy,
    'fiscal_month', p_fiscal_month,
    'days',
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'day', d.day_no,
            'date', d.gregorian_date,
            'nepali_date', d.nepali_date,
            'amount', d.amount,
            'prior_amount', d.prior_amount,
            'yoy_growth',
              case
                when d.prior_amount <> 0
                  then round((d.amount / d.prior_amount - 1) * 100, 2)
                else null
              end,
            'cumulative_amount', d.cumulative_amount,
            'cumulative_prior_amount', d.cumulative_prior_amount,
            'cumulative_yoy_growth',
              case
                when d.cumulative_prior_amount <> 0
                  then round((d.cumulative_amount / d.cumulative_prior_amount - 1) * 100, 2)
                else null
              end,
            'cumulative_categories', coalesce(cj.categories, '[]'::jsonb)
          )
          order by d.day_no
        ),
        '[]'::jsonb
      )
  )
  into v_result
  from day_values d
  left join category_json cj on cj.day_no = d.day_no;

  return v_result;
end;
$$;

revoke all on function public.get_executive_monthly_pulse(text, integer) from public, anon;
grant execute on function public.get_executive_monthly_pulse(text, integer) to authenticated;
