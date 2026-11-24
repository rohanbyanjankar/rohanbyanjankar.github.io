-- Contribution of Classification 1 categories to tax-revenue change.
create or replace function public.get_tax_revenue_growth_decomposition(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
 v_fy text;
 v_prev text;
 v_cutoff integer;
 v_out jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select trim(fiscal_year) into v_fy
 from public.fiscal_calendar
 where trim(fiscal_year)=trim(p_fiscal_year)
 order by gregorian_date desc limit 1;
 if v_fy is null then return jsonb_build_object('ready',false,'message','Fiscal year not found'); end if;
 select max(c.fiscal_day) into v_cutoff
 from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
 where trim(c.fiscal_year)=v_fy;
 if v_cutoff is null then return jsonb_build_object('ready',false,'message','No revenue observations found'); end if;
 v_prev:=public.previous_fiscal_year(v_fy);
 with scope as (
  select trim(c.fiscal_year) fiscal_year,r.collection_amount,
   coalesce(nullif(trim(rule.classification1),''),'Unclassified') category,
   coalesce(nullif(trim(rule.classification2),''),nullif(trim(rule.classification),''),'Unclassified') class2,
   coalesce(rule.action,'classify') action
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  left join lateral (
   select classification1,classification2,classification,action
   from public.revenue_classification_rules
   where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc limit 1
  ) rule on true
  where trim(c.fiscal_year) in (v_fy,trim(v_prev))
   and c.fiscal_day<=v_cutoff
   and coalesce(rule.action,'classify')<>'omit'
   and lower(trim(coalesce(nullif(trim(rule.classification2),''),nullif(trim(rule.classification),''),''))) in ('tax revenue','tax')
 ), grouped as (
  select category,
   coalesce(sum(collection_amount) filter(where fiscal_year=v_fy),0)::numeric current_amount,
   coalesce(sum(collection_amount) filter(where fiscal_year=trim(v_prev)),0)::numeric prior_amount
  from scope group by category
 )
 select jsonb_build_object(
  'ready',true,'fiscal_year',v_fy,'previous_fiscal_year',v_prev,'cutoff_day',v_cutoff,
  'categories',coalesce(jsonb_agg(jsonb_build_object(
   'category',category,'current',current_amount,'prior',prior_amount,
   'change',current_amount-prior_amount,
   'growth',case when prior_amount<>0 then round((current_amount/prior_amount-1)*100,2) else null end
  ) order by abs(current_amount-prior_amount) desc),'[]'::jsonb)
 ) into v_out from grouped;
 return v_out;
end;
$$;
revoke all on function public.get_tax_revenue_growth_decomposition(text) from public,anon;
grant execute on function public.get_tax_revenue_growth_decomposition(text) to authenticated;
