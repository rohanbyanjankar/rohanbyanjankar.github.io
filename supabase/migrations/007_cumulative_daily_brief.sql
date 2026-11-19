-- Add fiscal-year-to-date values to each daily heatmap cell.
-- The daily heatmap remains daily; the lightbox uses cumulative values through the selected fiscal day.
create or replace function public.get_executive_monthly_pulse(
  p_fiscal_year text,
  p_fiscal_month integer
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  prev text;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_fiscal_month < 1 or p_fiscal_month > 12 then raise exception 'Fiscal month must be between 1 and 12'; end if;
  prev := public.previous_fiscal_year(p_fiscal_year);

  with current_calendar as (
    select gregorian_date,nepali_date,fiscal_day,
      row_number() over(order by gregorian_date)::int day_no
    from public.fiscal_calendar
    where fiscal_year=p_fiscal_year and fiscal_month=p_fiscal_month
  ),
  prior_calendar as (
    select gregorian_date,
      row_number() over(order by gregorian_date)::int day_no
    from public.fiscal_calendar
    where fiscal_year=prev and fiscal_month=p_fiscal_month
  ),
  current_rows as (
    select c.day_no,c.fiscal_day,
      case
        when lower(coalesce(rule.classification,''))='vat' then 'VAT'
        when lower(coalesce(rule.classification,''))='excise' then 'Excise'
        when lower(coalesce(rule.classification,''))='customs' then 'Customs'
        when lower(coalesce(rule.classification,'')) in ('income tax','income-tax') then 'Income Tax'
        when lower(coalesce(rule.classification,'')) in ('interest and dividends','interest & dividends') then 'Interest and Dividends'
        when lower(coalesce(rule.classification,''))='royalty' then 'Royalty'
        else 'Unclassified'
      end category,
      r.collection_amount amount
    from current_calendar c
    join public.revenue_daily r on r.collection_date=c.gregorian_date
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where coalesce(rule.action,'classify')<>'omit'
  ),
  prior_rows as (
    select c.day_no,c.fiscal_day,
      case
        when lower(coalesce(rule.classification,''))='vat' then 'VAT'
        when lower(coalesce(rule.classification,''))='excise' then 'Excise'
        when lower(coalesce(rule.classification,''))='customs' then 'Customs'
        when lower(coalesce(rule.classification,'')) in ('income tax','income-tax') then 'Income Tax'
        when lower(coalesce(rule.classification,'')) in ('interest and dividends','interest & dividends') then 'Interest and Dividends'
        when lower(coalesce(rule.classification,''))='royalty' then 'Royalty'
        else 'Unclassified'
      end category,
      r.collection_amount amount
    from prior_calendar c
    join public.revenue_daily r on r.collection_date=c.gregorian_date
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where coalesce(rule.action,'classify')<>'omit'
  ),
  categories(category,sort_order) as (
    values ('VAT',1),('Excise',2),('Customs',3),('Income Tax',4),
           ('Unclassified',5),('Interest and Dividends',6),('Royalty',7)
  ),
  day_rows as (
    select c.day_no,c.gregorian_date,c.nepali_date,c.fiscal_day,
      coalesce((select sum(x.amount) from current_rows x where x.day_no=c.day_no),0) amount,
      coalesce((select sum(x.amount) from prior_rows x where x.day_no=c.day_no),0) prior_amount,
      coalesce((select sum(x.amount) from current_rows x where x.fiscal_day<=c.fiscal_day),0) cumulative_amount,
      coalesce((select sum(x.amount) from prior_rows x where x.fiscal_day<=c.fiscal_day),0) cumulative_prior_amount
    from current_calendar c
  )
  select jsonb_build_object(
    'fiscal_year',p_fiscal_year,
    'previous_fiscal_year',prev,
    'fiscal_month',p_fiscal_month,
    'days',coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'day',d.day_no,
          'date',d.gregorian_date,
          'nepali_date',d.nepali_date,
          'amount',d.amount,
          'prior_amount',d.prior_amount,
          'yoy_growth',case when d.prior_amount<>0 then round((d.amount/d.prior_amount-1)*100,2) else null end,
          'cumulative_amount',d.cumulative_amount,
          'cumulative_prior_amount',d.cumulative_prior_amount,
          'cumulative_yoy_growth',case when d.cumulative_prior_amount<>0 then round((d.cumulative_amount/d.cumulative_prior_amount-1)*100,2) else null end,
          'cumulative_categories',(
            select jsonb_agg(jsonb_build_object(
              'name',cat.category,
              'amount',coalesce((select sum(x.amount) from current_rows x where x.fiscal_day<=d.fiscal_day and x.category=cat.category),0),
              'prior_amount',coalesce((select sum(x.amount) from prior_rows x where x.fiscal_day<=d.fiscal_day and x.category=cat.category),0),
              'yoy_growth',case
                when coalesce((select sum(x.amount) from prior_rows x where x.fiscal_day<=d.fiscal_day and x.category=cat.category),0)<>0
                then round((
                  coalesce((select sum(x.amount) from current_rows x where x.fiscal_day<=d.fiscal_day and x.category=cat.category),0)
                  / (select sum(x.amount) from prior_rows x where x.fiscal_day<=d.fiscal_day and x.category=cat.category)-1
                )*100,2) else null end
            ) order by cat.sort_order)
            from categories cat
          )
        ) order by d.day_no
      ) from day_rows d
    ),'[]'::jsonb)
  ) into result;
  return result;
end $$;

revoke all on function public.get_executive_monthly_pulse(text,integer) from public,anon;
grant execute on function public.get_executive_monthly_pulse(text,integer) to authenticated;
