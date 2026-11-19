-- Add daily same-day YoY and fiscal-year-to-date YoY to the daily executive brief.
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

  with month_calendar as (
    select gregorian_date,nepali_date,fiscal_day,
      row_number() over(order by gregorian_date)::int day_no
    from public.fiscal_calendar
    where fiscal_year=p_fiscal_year and fiscal_month=p_fiscal_month
  ),
  relevant_calendar as (
    select gregorian_date,fiscal_year,fiscal_day
    from public.fiscal_calendar
    where fiscal_year in (p_fiscal_year,prev)
  ),
  classified_rows as (
    select c.fiscal_year,c.fiscal_day,r.collection_date,
      case
        when lower(trim(coalesce(rule.classification,''))) like '%vat%' then 'VAT'
        when lower(trim(coalesce(rule.classification,''))) like '%excise%' then 'Excise'
        when lower(trim(coalesce(rule.classification,''))) like '%custom%' then 'Customs'
        when lower(trim(coalesce(rule.classification,''))) like '%income%tax%'
          or lower(trim(coalesce(rule.classification,''))) like '%direct%tax%'
          or lower(trim(coalesce(rule.classification,''))) like '%tax%income%' then 'Income Tax'
        when lower(trim(coalesce(rule.classification,''))) like '%interest%'
          or lower(trim(coalesce(rule.classification,''))) like '%dividend%' then 'Interest and Dividends'
        when lower(trim(coalesce(rule.classification,''))) like '%royalt%' then 'Royalty'
        else 'Unclassified'
      end category,
      r.collection_amount amount
    from relevant_calendar c
    join public.revenue_daily r on r.collection_date=c.gregorian_date
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where coalesce(rule.action,'classify')<>'omit'
  ),
  daily_values as (
    select mc.day_no,mc.gregorian_date,mc.nepali_date,mc.fiscal_day,
      coalesce((select sum(x.amount) from classified_rows x
        where x.fiscal_year=p_fiscal_year and x.fiscal_day=mc.fiscal_day),0) daily_amount,
      coalesce((select sum(x.amount) from classified_rows x
        where x.fiscal_year=prev and x.fiscal_day=mc.fiscal_day),0) prior_daily_amount,
      coalesce((select sum(x.amount) from classified_rows x
        where x.fiscal_year=p_fiscal_year and x.fiscal_day<=mc.fiscal_day),0) cumulative_amount,
      coalesce((select sum(x.amount) from classified_rows x
        where x.fiscal_year=prev and x.fiscal_day<=mc.fiscal_day),0) prior_cumulative_amount
    from month_calendar mc
  ),
  categories(category,sort_order) as (
    values ('VAT',1),('Income Tax',2),('Customs',3),('Excise',4)
  )
  select jsonb_build_object(
    'fiscal_year',p_fiscal_year,
    'previous_fiscal_year',prev,
    'fiscal_month',p_fiscal_month,
    'days',coalesce((
      select jsonb_agg(jsonb_build_object(
        'day',d.day_no,
        'date',d.gregorian_date,
        'nepali_date',d.nepali_date,
        'amount',d.daily_amount,
        'prior_amount',d.prior_daily_amount,
        'yoy_growth',case when d.prior_daily_amount<>0
          then round((d.daily_amount/d.prior_daily_amount-1)*100,2) else null end,
        'cumulative_amount',d.cumulative_amount,
        'cumulative_prior_amount',d.prior_cumulative_amount,
        'cumulative_yoy_growth',case when d.prior_cumulative_amount<>0
          then round((d.cumulative_amount/d.prior_cumulative_amount-1)*100,2) else null end,
        'cumulative_categories',(
          select jsonb_agg(jsonb_build_object(
            'name',cat.category,
            'amount',coalesce((select sum(x.amount) from classified_rows x
              where x.fiscal_year=p_fiscal_year and x.fiscal_day<=d.fiscal_day and x.category=cat.category),0),
            'prior_amount',coalesce((select sum(x.amount) from classified_rows x
              where x.fiscal_year=prev and x.fiscal_day<=d.fiscal_day and x.category=cat.category),0),
            'cumulative_yoy_growth',case
              when coalesce((select sum(x.amount) from classified_rows x
                where x.fiscal_year=prev and x.fiscal_day<=d.fiscal_day and x.category=cat.category),0)<>0
              then round((
                coalesce((select sum(x.amount) from classified_rows x
                  where x.fiscal_year=p_fiscal_year and x.fiscal_day<=d.fiscal_day and x.category=cat.category),0)
                / (select sum(x.amount) from classified_rows x
                  where x.fiscal_year=prev and x.fiscal_day<=d.fiscal_day and x.category=cat.category)-1
              )*100,2) else null end,
            'daily_yoy_growth',case
              when coalesce((select sum(x.amount) from classified_rows x
                where x.fiscal_year=prev and x.fiscal_day=d.fiscal_day and x.category=cat.category),0)<>0
              then round((
                coalesce((select sum(x.amount) from classified_rows x
                  where x.fiscal_year=p_fiscal_year and x.fiscal_day=d.fiscal_day and x.category=cat.category),0)
                / (select sum(x.amount) from classified_rows x
                  where x.fiscal_year=prev and x.fiscal_day=d.fiscal_day and x.category=cat.category)-1
              )*100,2) else null end
          ) order by cat.sort_order)
          from categories cat
        )
      ) order by d.day_no)
      from daily_values d
    ),'[]'::jsonb)
  ) into result;
  return result;
end $$;

revoke all on function public.get_executive_monthly_pulse(text,integer) from public,anon;
grant execute on function public.get_executive_monthly_pulse(text,integer) to authenticated;
