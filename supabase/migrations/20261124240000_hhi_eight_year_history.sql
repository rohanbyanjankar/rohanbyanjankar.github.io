-- Fiscal-year HHI history, grouped by Classification 1.
-- Each fiscal year uses all revenue observations available within that year.
-- Completed years are full-year values; the current year is year-to-date and
-- updates as new revenue observations are imported.
create or replace function public.get_revenue_concentration_hhi_history(
 p_fiscal_year text
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 v_fy text;
 v_start date;
 v_out jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;

 select trim(fiscal_year),min(gregorian_date)
 into v_fy,v_start
 from public.fiscal_calendar
 where trim(fiscal_year)=trim(p_fiscal_year)
 group by trim(fiscal_year);

 if v_fy is null then
  return jsonb_build_object('ready',false,'message','Fiscal year not found');
 end if;

 with year_cutoffs as (
  select trim(c.fiscal_year) fiscal_year,
   min(c.gregorian_date) start_date,
   max(c.fiscal_day) calendar_cutoff_day
  from public.fiscal_calendar c
  where c.gregorian_date<=(
   select max(gregorian_date)
   from public.fiscal_calendar
   where trim(fiscal_year)=v_fy
  )
  group by trim(c.fiscal_year)
 ), observed_years as (
  select yc.fiscal_year,yc.start_date,
   max(c.fiscal_day) observed_cutoff_day
  from year_cutoffs yc
  join public.fiscal_calendar c on trim(c.fiscal_year)=yc.fiscal_year
  join public.revenue_daily r on r.collection_date=c.gregorian_date
  group by yc.fiscal_year,yc.start_date
 ), scope as (
  select trim(c.fiscal_year) fiscal_year,r.collection_amount,
   coalesce(nullif(trim(rule.classification1),''),'Unclassified') classification1,
   coalesce(rule.action,'classify') action
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  join observed_years oy on oy.fiscal_year=trim(c.fiscal_year)
   and c.fiscal_day<=oy.observed_cutoff_day
  left join lateral (
   select classification1,action
   from public.revenue_classification_rules
   where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc
   limit 1
  ) rule on true
  where coalesce(rule.action,'classify')<>'omit'
 ), by_category as (
  select fiscal_year,classification1,
   sum(greatest(collection_amount,0)) amount
  from scope
  group by fiscal_year,classification1
 ), totals as (
  select fiscal_year,sum(amount) total_positive
  from by_category
  group by fiscal_year
 ), shares as (
  select b.fiscal_year,b.classification1,b.amount,t.total_positive,
   b.amount/nullif(t.total_positive,0) share
  from by_category b
  join totals t using(fiscal_year)
 ), metrics as (
  select fiscal_year,
   round(sum(power(share,2))*10000,2) hhi,
   count(*) filter(where amount>0) active_categories,
   round(max(share)*100,2) largest_category_share,
   max(total_positive) total_positive
  from shares
  group by fiscal_year
 )
 select jsonb_build_object(
  'ready',true,
  'selected_fiscal_year',v_fy,
  'classification_level','classification1',
  'years',coalesce(jsonb_agg(jsonb_build_object(
    'fiscal_year',oy.fiscal_year,
    'hhi',m.hhi,
    'effective_categories',case when coalesce(m.hhi,0)>0 then round(10000/m.hhi,2) else null end,
    'active_categories',m.active_categories,
    'largest_category_share',m.largest_category_share,
    'total_positive',m.total_positive,
    'cutoff_day',oy.observed_cutoff_day,
    'period_type',case when oy.fiscal_year=v_fy then 'year_to_date' else 'available_fiscal_year' end
   ) order by oy.start_date),'[]'::jsonb)
 ) into v_out
 from observed_years oy
 left join metrics m using(fiscal_year);

 return v_out;
end;
$$;

revoke all on function public.get_revenue_concentration_hhi_history(text) from public,anon;
grant execute on function public.get_revenue_concentration_hhi_history(text) to authenticated;
