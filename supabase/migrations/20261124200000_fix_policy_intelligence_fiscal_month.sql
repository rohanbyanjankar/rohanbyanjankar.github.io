-- Fix missing fiscal_month in the policy intelligence scope CTE.
-- The monthly momentum calculation groups the comparable-period records by
-- fiscal_month, so the field must be selected from fiscal_calendar.

create or replace function public.get_revenue_policy_intelligence(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fy text;
  v_prev text;
  v_cutoff_day integer;
  v_cutoff_date date;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;

  select c.fiscal_year into v_fy
  from public.fiscal_calendar c
  where trim(c.fiscal_year)=trim(p_fiscal_year)
  order by c.gregorian_date desc limit 1;
  if v_fy is null then
    return jsonb_build_object('ready',false,'message','Selected fiscal year was not found in the fiscal calendar.');
  end if;

  select max(c.fiscal_day),max(c.gregorian_date)
    into v_cutoff_day,v_cutoff_date
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  where trim(c.fiscal_year)=trim(v_fy);
  if v_cutoff_day is null then
    return jsonb_build_object('ready',false,'message','No revenue observations were found for the selected fiscal year.');
  end if;
  v_prev:=public.previous_fiscal_year(v_fy);

  with scope as (
    select c.fiscal_year,c.fiscal_day,c.fiscal_month,c.gregorian_date,
      r.revenue_head_id as code,
      coalesce(h.description,r.revenue_description,r.revenue_head_id) as description,
      r.collection_amount,
      coalesce(nullif(trim(rule.classification1),''),'Unclassified') as class1,
      coalesce(nullif(trim(rule.classification2),''),nullif(trim(rule.classification),''),'Unclassified') as class2,
      coalesce(rule.action,'classify') as action
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date=r.collection_date
    left join public.revenue_heads h on h.code=r.revenue_head_id
    left join lateral (
      select classification1,classification2,classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where (trim(c.fiscal_year)=trim(v_fy) or trim(c.fiscal_year)=trim(v_prev))
      and c.fiscal_day<=v_cutoff_day
      and coalesce(rule.action,'classify')<>'omit'
  ),
  totals as (
    select
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_net,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_net,
      coalesce(sum(greatest(collection_amount,0)) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric gross_positive,
      coalesce(sum(abs(least(collection_amount,0))) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric negative_adjustments,
      count(*) filter(where trim(fiscal_year)=trim(v_fy))::integer observations,
      count(distinct code) filter(where trim(fiscal_year)=trim(v_fy))::integer active_heads
    from scope
  ),
  categories_raw as (
    select class2 category,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_amount,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_amount
    from scope group by class2
  ),
  categories as (
    select coalesce(jsonb_agg(jsonb_build_object('category',category,'current',current_amount,'prior',prior_amount,
      'change',current_amount-prior_amount,'growth',case when prior_amount<>0 then round((current_amount/prior_amount-1)*100,2) else null end)
      order by abs(current_amount-prior_amount) desc),'[]'::jsonb) value from categories_raw
  ),
  heads_raw as (
    select code,max(description) description,max(class1) classification1,max(class2) classification2,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_amount,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_amount
    from scope group by code
  ),
  heads_ranked as (
    select *,current_amount-prior_amount change,
      row_number() over(order by current_amount desc) current_rank
    from heads_raw
  ),
  head_summary as (
    select coalesce(sum(current_amount) filter(where current_rank<=5),0)::numeric top5_amount,
      coalesce(sum(current_amount) filter(where current_rank<=10),0)::numeric top10_amount
    from heads_ranked
  ),
  top_movers as (
    select coalesce(jsonb_agg(jsonb_build_object('code',code,'description',description,'classification1',classification1,
      'classification2',classification2,'current',current_amount,'prior',prior_amount,'change',change,
      'growth',case when prior_amount<>0 then round((current_amount/prior_amount-1)*100,2) else null end)
      order by change desc),'[]'::jsonb) value
    from (select * from heads_ranked where change>0 order by change desc limit 8) x
  ),
  declining as (
    select coalesce(jsonb_agg(jsonb_build_object('code',code,'description',description,'classification1',classification1,
      'classification2',classification2,'current',current_amount,'prior',prior_amount,'change',change,
      'growth',case when prior_amount<>0 then round((current_amount/prior_amount-1)*100,2) else null end)
      order by change),'[]'::jsonb) value
    from (select * from heads_ranked where change<0 order by change limit 8) x
  ),
  months as (
    select fiscal_month,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_amount,
      coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_amount
    from scope group by fiscal_month
  ),
  monthly as (
    select coalesce(jsonb_agg(jsonb_build_object('month',m.month_no,'current',coalesce(x.current_amount,0),
      'prior',coalesce(x.prior_amount,0)) order by m.month_no),'[]'::jsonb) value
    from generate_series(1,12) m(month_no)
    left join months x on x.fiscal_month=m.month_no
  )
  select jsonb_build_object(
    'ready',true,'fiscal_year',v_fy,'previous_fiscal_year',v_prev,'cutoff_day',v_cutoff_day,'cutoff_date',v_cutoff_date,
    'current_net',(select current_net from totals),'prior_net',(select prior_net from totals),
    'gross_positive',(select gross_positive from totals),'negative_adjustments',(select negative_adjustments from totals),
    'observations',(select observations from totals),'active_heads',(select active_heads from totals),
    'top5_share',case when (select current_net from totals)<>0 then round((select top5_amount from head_summary)/(select current_net from totals)*100,2) else null end,
    'top10_share',case when (select current_net from totals)<>0 then round((select top10_amount from head_summary)/(select current_net from totals)*100,2) else null end,
    'categories',(select value from categories),'top_growing_heads',(select value from top_movers),
    'declining_heads',(select value from declining),'monthly',(select value from monthly)
  ) into v_result;
  return v_result;
end;
$$;

revoke all on function public.get_revenue_policy_intelligence(text) from public,anon;
grant execute on function public.get_revenue_policy_intelligence(text) to authenticated;
