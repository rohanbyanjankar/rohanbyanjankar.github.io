-- Correct daily revenue brief: cumulative means fiscal-year-to-date, not month-to-date.
-- The daily heatmap remains daily; the clicked-day lightbox reports cumulative FYTD amounts only.
create or replace function public.get_executive_monthly_pulse(
  p_fiscal_year text,
  p_fiscal_month integer
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_fiscal_month < 1 or p_fiscal_month > 12 then
    raise exception 'Fiscal month must be between 1 and 12';
  end if;

  with month_calendar as (
    select gregorian_date,nepali_date,fiscal_day,
      row_number() over(order by gregorian_date)::int day_no
    from public.fiscal_calendar
    where fiscal_year=p_fiscal_year and fiscal_month=p_fiscal_month
  ),
  fy_rows as (
    select c.fiscal_day,
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
    from public.fiscal_calendar c
    join public.revenue_daily r on r.collection_date=c.gregorian_date
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where c.fiscal_year=p_fiscal_year
      and coalesce(rule.action,'classify')<>'omit'
  ),
  daily_rows as (
    select c.day_no,c.gregorian_date,c.nepali_date,c.fiscal_day,
      coalesce(sum(r.collection_amount),0) amount
    from month_calendar c
    left join public.revenue_daily r on r.collection_date=c.gregorian_date
      and not exists (
        select 1 from public.revenue_classification_rules q
        where q.is_active and q.action='omit'
          and r.revenue_head_id like q.code_prefix||'%'
      )
    group by c.day_no,c.gregorian_date,c.nepali_date,c.fiscal_day
  ),
  categories(category,sort_order) as (
    values ('VAT',1),('Income Tax',2),('Customs',3),('Excise',4),
           ('Unclassified',5),('Interest and Dividends',6),('Royalty',7)
  )
  select jsonb_build_object(
    'fiscal_year',p_fiscal_year,
    'fiscal_month',p_fiscal_month,
    'days',coalesce((
      select jsonb_agg(jsonb_build_object(
        'day',d.day_no,
        'date',d.gregorian_date,
        'nepali_date',d.nepali_date,
        'amount',d.amount,
        'cumulative_amount',coalesce((
          select sum(x.amount) from fy_rows x where x.fiscal_day<=d.fiscal_day
        ),0),
        'cumulative_categories',(
          select jsonb_agg(jsonb_build_object(
            'name',cat.category,
            'amount',coalesce((
              select sum(x.amount) from fy_rows x
              where x.fiscal_day<=d.fiscal_day and x.category=cat.category
            ),0)
          ) order by cat.sort_order)
          from categories cat
        )
      ) order by d.day_no)
      from daily_rows d
    ),'[]'::jsonb)
  ) into result;
  return result;
end $$;

revoke all on function public.get_executive_monthly_pulse(text,integer) from public,anon;
grant execute on function public.get_executive_monthly_pulse(text,integer) to authenticated;
