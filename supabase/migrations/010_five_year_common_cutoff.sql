-- Five-year comparison using one common fiscal-day cutoff across all years.
-- The default cutoff is the latest date with stored revenue data in the selected fiscal year.
create or replace function public.get_five_year_revenue_comparison(
  p_fiscal_year text,
  p_cutoff_date date default null
) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
  cutoff_day integer;
  cutoff_date date;
  result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  if p_cutoff_date is not null then
    select fiscal_day into cutoff_day
    from public.fiscal_calendar
    where fiscal_year=p_fiscal_year and gregorian_date=p_cutoff_date;
    if cutoff_day is null then
      raise exception 'Selected cutoff date is not in fiscal year %',p_fiscal_year;
    end if;
    cutoff_date:=p_cutoff_date;
  else
    select c.fiscal_day,c.gregorian_date
      into cutoff_day,cutoff_date
    from public.fiscal_calendar c
    where c.fiscal_year=p_fiscal_year
      and exists(select 1 from public.revenue_daily r where r.collection_date=c.gregorian_date)
    order by c.gregorian_date desc limit 1;
  end if;

  if cutoff_day is null then
    raise exception 'No revenue observations found in fiscal year %',p_fiscal_year;
  end if;

  with selected_years as (
    select fiscal_year,fy_start
    from (
      select fiscal_year,
        split_part(fiscal_year,'/',1)::integer fy_start,
        row_number() over(order by split_part(fiscal_year,'/',1)::integer desc) rn
      from (select distinct fiscal_year from public.fiscal_calendar) y
    ) s
    where rn between
      (select rn from (
        select fiscal_year,row_number() over(order by split_part(fiscal_year,'/',1)::integer desc) rn
        from (select distinct fiscal_year from public.fiscal_calendar) z
      ) q where fiscal_year=p_fiscal_year)
      and
      (select rn+4 from (
        select fiscal_year,row_number() over(order by split_part(fiscal_year,'/',1)::integer desc) rn
        from (select distinct fiscal_year from public.fiscal_calendar) z
      ) q where fiscal_year=p_fiscal_year)
  ),
  categorized as (
    select c.fiscal_year,
      case
        when lower(trim(coalesce(rule.classification,''))) like '%vat%' then 'VAT'
        when lower(trim(coalesce(rule.classification,''))) like '%excise%' then 'Excise'
        when lower(trim(coalesce(rule.classification,''))) like '%custom%' then 'Customs'
        when lower(trim(coalesce(rule.classification,''))) like '%income%tax%'
          or lower(trim(coalesce(rule.classification,''))) like '%direct%tax%'
          or lower(trim(coalesce(rule.classification,''))) like '%tax%income%' then 'Income Tax'
        when lower(trim(coalesce(rule.classification,''))) like '%interest%'
          or lower(trim(coalesce(rule.classification,''))) like '%dividend%' then 'Interest and dividends'
        when lower(trim(coalesce(rule.classification,''))) like '%royalt%' then 'Royalty'
        when coalesce(rule.action,'classify')='omit' then 'Omitted'
        else 'Unclassified'
      end category,
      sum(r.collection_amount) amount
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date=r.collection_date
    join selected_years sy on sy.fiscal_year=c.fiscal_year
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where c.fiscal_day<=cutoff_day
      and coalesce(rule.action,'classify')<>'omit'
    group by c.fiscal_year,category
  ),
  years_data as (
    select sy.fiscal_year,sy.fy_start,
      coalesce(sum(c.amount),0) total,
      coalesce(sum(c.amount) filter(where c.category='VAT'),0) vat,
      coalesce(sum(c.amount) filter(where c.category='Excise'),0) excise,
      coalesce(sum(c.amount) filter(where c.category='Customs'),0) customs,
      coalesce(sum(c.amount) filter(where c.category='Income Tax'),0) income_tax,
      coalesce(sum(c.amount) filter(where c.category='Unclassified'),0) unclassified,
      coalesce(sum(c.amount) filter(where c.category='Interest and dividends'),0) interest_dividends,
      coalesce(sum(c.amount) filter(where c.category='Royalty'),0) royalty
    from selected_years sy
    left join categorized c on c.fiscal_year=sy.fiscal_year
    group by sy.fiscal_year,sy.fy_start
  )
  select jsonb_build_object(
    'selected_fiscal_year',p_fiscal_year,
    'cutoff_date',cutoff_date,
    'cutoff_fiscal_day',cutoff_day,
    'years',coalesce(jsonb_agg(jsonb_build_object(
      'fiscal_year',fiscal_year,'total',total,
      'tax_revenue',vat+excise+customs+income_tax+unclassified,
      'vat',vat,'excise',excise,'customs',customs,'income_tax',income_tax,
      'unclassified',unclassified,
      'non_tax_revenue',interest_dividends+royalty,
      'interest_dividends',interest_dividends,'royalty',royalty
    ) order by fy_start desc),'[]'::jsonb)
  ) into result
  from years_data;
  return result;
end $$;

revoke all on function public.get_five_year_revenue_comparison(text,date) from public,anon;
grant execute on function public.get_five_year_revenue_comparison(text,date) to authenticated;
