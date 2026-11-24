-- Revenue-head concentration measured using the Herfindahl-Hirschman Index.
-- Shares are based on positive gross collections by distinct revenue head.
-- Current and prior periods are matched through the same fiscal day.
create or replace function public.get_revenue_concentration_hhi(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_fy text; v_prev text; v_day integer; v_date date; v_out jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select fiscal_year into v_fy from public.fiscal_calendar
 where trim(fiscal_year)=trim(p_fiscal_year)
 order by gregorian_date desc limit 1;
 if v_fy is null then return jsonb_build_object('ready',false,'message','Fiscal year not found'); end if;
 select max(c.fiscal_day),max(c.gregorian_date) into v_day,v_date
 from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
 where trim(c.fiscal_year)=trim(v_fy);
 if v_day is null then return jsonb_build_object('ready',false,'message','No revenue observations found'); end if;
 v_prev:=public.previous_fiscal_year(v_fy);
 with scope as (
  select trim(c.fiscal_year) fy,r.revenue_head_id code,r.collection_amount,
   coalesce(rule.action,'classify') action
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  left join lateral (
   select action from public.revenue_classification_rules
   where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc limit 1
  ) rule on true
  where trim(c.fiscal_year) in (trim(v_fy),trim(v_prev))
   and c.fiscal_day<=v_day and coalesce(rule.action,'classify')<>'omit'
 ), by_head as (
  select fy,code,sum(greatest(collection_amount,0)) amount
  from scope group by fy,code
 ), shares as (
  select fy,code,amount,sum(amount) over(partition by fy) total
  from by_head
 ), hhi as (
  select fy,
   sum(power(amount/nullif(total,0),2))*10000 hhi_points,
   count(*) filter(where amount>0) active_heads,
   max(amount/nullif(total,0))*100 largest_share
  from shares group by fy
 )
 select jsonb_build_object(
  'ready',true,'fiscal_year',v_fy,'previous_fiscal_year',v_prev,
  'cutoff_day',v_day,'cutoff_date',v_date,
  'current_hhi',round((select hhi_points from hhi where fy=trim(v_fy)),2),
  'prior_hhi',round((select hhi_points from hhi where fy=trim(v_prev)),2),
  'current_effective_heads',case when coalesce((select hhi_points from hhi where fy=trim(v_fy)),0)>0 then round(10000/(select hhi_points from hhi where fy=trim(v_fy)),2) else null end,
  'prior_effective_heads',case when coalesce((select hhi_points from hhi where fy=trim(v_prev)),0)>0 then round(10000/(select hhi_points from hhi where fy=trim(v_prev)),2) else null end,
  'current_largest_head_share',round((select largest_share from hhi where fy=trim(v_fy)),2),
  'prior_largest_head_share',round((select largest_share from hhi where fy=trim(v_prev)),2),
  'current_active_heads',(select active_heads from hhi where fy=trim(v_fy)),
  'prior_active_heads',(select active_heads from hhi where fy=trim(v_prev))
 ) into v_out;
 return v_out;
end;
$$;
revoke all on function public.get_revenue_concentration_hhi(text) from public,anon;
grant execute on function public.get_revenue_concentration_hhi(text) to authenticated;
