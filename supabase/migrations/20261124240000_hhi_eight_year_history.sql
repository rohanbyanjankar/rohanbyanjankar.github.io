-- Dynamic rolling HHI history, grouped by Classification 1.
-- All fiscal years use the same fiscal-day cutoff for comparability.
create or replace function public.get_revenue_concentration_hhi_history(
 p_fiscal_year text,
 p_years integer default 8
) returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 v_fy text;
 v_cutoff integer;
 v_start date;
 v_out jsonb;
 v_n integer := greatest(2,least(coalesce(p_years,8),20));
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
 select max(c.fiscal_day) into v_cutoff
 from public.revenue_daily r
 join public.fiscal_calendar c on c.gregorian_date=r.collection_date
 where trim(c.fiscal_year)=v_fy;
 if v_cutoff is null then
  return jsonb_build_object('ready',false,'message','No revenue observations found for the selected fiscal year');
 end if;
 with all_years as (
  select trim(fiscal_year) fiscal_year,min(gregorian_date) start_date
  from public.fiscal_calendar
  group by trim(fiscal_year)
 ), window_years as (
  select fiscal_year,start_date
  from all_years
  where start_date<=v_start
  order by start_date desc
  limit v_n
 ), scope as (
  select trim(c.fiscal_year) fiscal_year,r.collection_amount,
   coalesce(nullif(trim(rule.classification1),''),'Unclassified') classification1,
   coalesce(rule.action,'classify') action
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  join window_years wy on wy.fiscal_year=trim(c.fiscal_year)
  left join lateral (
   select classification1,action
   from public.revenue_classification_rules
   where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc
   limit 1
  ) rule on true
  where c.fiscal_day<=v_cutoff
    and coalesce(rule.action,'classify')<>'omit'
 ), by_category as (
  select fiscal_year,classification1,sum(greatest(collection_amount,0)) amount
  from scope
  group by fiscal_year,classification1
 ), totals as (
  select fiscal_year,sum(amount) total_positive
  from by_category
  group by fiscal_year
 ), shares as (
  select b.fiscal_year,b.classification1,b.amount,t.total_positive,
   b.amount/nullif(t.total_positive,0) share
  from by_category b join totals t using(fiscal_year)
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
  'fiscal_year',v_fy,
  'window_years',v_n,
  'cutoff_day',v_cutoff,
  'classification_level','classification1',
  'years',coalesce(jsonb_agg(jsonb_build_object(
    'fiscal_year',wy.fiscal_year,
    'hhi',m.hhi,
    'effective_categories',case when coalesce(m.hhi,0)>0 then round(10000/m.hhi,2) else null end,
    'active_categories',m.active_categories,
    'largest_category_share',m.largest_category_share,
    'total_positive',m.total_positive
   ) order by wy.start_date),'[]'::jsonb)
 ) into v_out
 from window_years wy
 left join metrics m using(fiscal_year);
 return v_out;
end;
$$;
revoke all on function public.get_revenue_concentration_hhi_history(text,integer) from public,anon;
grant execute on function public.get_revenue_concentration_hhi_history(text,integer) to authenticated;
