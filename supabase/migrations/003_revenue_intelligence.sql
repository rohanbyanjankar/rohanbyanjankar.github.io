-- Revenue Intelligence v3: signed revenue adjustments and analytical aggregates
-- Apply after migrations 001 and 002.

-- Negative collections are valid accounting adjustments, refunds and reversals.
alter table public.revenue_daily drop constraint if exists revenue_daily_collection_amount_check;

drop function if exists public.import_revenue_batch(jsonb,uuid);
create or replace function public.import_revenue_batch(p_rows jsonb, p_upload_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n integer:=0; dup integer:=0; bad integer:=0; total integer:=jsonb_array_length(p_rows);
begin
 if not public.is_editor() then raise exception 'Insufficient permission'; end if;
 with parsed as (
   select nullif(v->>'collection_date','')::date d,
          nullif(trim(v->>'revenue_head_id'),'') code,
          coalesce(nullif(v->>'revenue_description',''),nullif(v->>'revenue_desc',''),nullif(v->>'REVENUE_DESC','')) descr,
          nullif(replace(coalesce(v->>'collection_amount',''),',',''),'')::numeric amount
   from jsonb_array_elements(p_rows) v
 ), valid as (
   select * from parsed where d is not null and code is not null and amount is not null
 ), heads as (
   insert into public.revenue_heads(code,description,level)
   select distinct code,coalesce(descr,code),3
   from valid on conflict(code) do nothing returning code
 ), ins as (
   insert into public.revenue_daily(collection_date,revenue_head_id,revenue_description,collection_amount,upload_id)
   select d,code,descr,amount,p_upload_id from valid cross join (select count(*) from heads) dependency
   on conflict(collection_date,revenue_head_id) do nothing returning 1
 ) select count(*) into n from ins;
 select count(*) into bad from jsonb_array_elements(p_rows) v
 where coalesce(v->>'collection_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
    or coalesce(trim(v->>'revenue_head_id'),'')=''
    or coalesce(replace(v->>'collection_amount',',',''),'') !~ '^-?[0-9]+([.][0-9]+)?$';
 dup:=greatest(0,total-n-bad);
 return jsonb_build_object('inserted',n,'duplicates',dup,'invalid',bad);
end $$;
revoke all on function public.import_revenue_batch(jsonb,uuid) from public,anon;
grant execute on function public.import_revenue_batch(jsonb,uuid) to authenticated;

create or replace function public.get_revenue_intelligence(p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fy text; prev text; outj jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select fiscal_year into fy from public.fiscal_calendar
 where p_fiscal_year is null or fiscal_year=p_fiscal_year
 order by gregorian_date desc limit 1;
 if fy is null then return jsonb_build_object('ready',false,'message','Fiscal calendar has not been loaded.'); end if;
 prev:=public.previous_fiscal_year(fy);
 with base as (
   select r.collection_date,r.revenue_head_id,r.collection_amount,c.fiscal_year,c.fiscal_month,c.fiscal_day,
     coalesce(rule.classification,'Unclassified') category,coalesce(rule.action,'classify') action,
     coalesce(h.description,r.revenue_description,r.revenue_head_id) description
   from public.revenue_daily r
   join public.fiscal_calendar c on c.gregorian_date=r.collection_date
   left join public.revenue_heads h on h.code=r.revenue_head_id
   left join lateral (
     select classification,action from public.revenue_classification_rules
     where is_active and r.revenue_head_id like code_prefix||'%'
     order by length(code_prefix) desc limit 1
   ) rule on true
   where c.fiscal_year in (fy,prev)
 ), kept as (select * from base where action<>'omit'),
 annual_raw as (
   select c.fiscal_year,sum(r.collection_amount) net,
     sum(greatest(r.collection_amount,0)) gross_positive,
     sum(abs(least(r.collection_amount,0))) negative_adjustments,
     count(*) observations,count(distinct r.revenue_head_id) heads
   from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
   where not exists(select 1 from public.revenue_classification_rules q where q.is_active and q.action='omit' and r.revenue_head_id like q.code_prefix||'%')
   group by c.fiscal_year
 ),
 annual as (
   select jsonb_agg(jsonb_build_object('fiscal_year',fiscal_year,'net',net,'gross_positive',gross_positive,'negative_adjustments',negative_adjustments,'observations',observations,'heads',heads) order by split_part(fiscal_year,'/',1)::int) v
   from (select * from annual_raw order by split_part(fiscal_year,'/',1)::int desc limit 10) a
 ),
 month_data as (
   select fiscal_month,sum(collection_amount) filter(where fiscal_year=fy) current_amount,
     sum(collection_amount) filter(where fiscal_year=prev) prior_amount
   from kept group by fiscal_month
 ),
 monthly as (
   select jsonb_agg(jsonb_build_object('month',m,'current',coalesce(current_amount,0),'prior',coalesce(prior_amount,0),
     'growth',case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end) order by m) v
   from generate_series(1,12) g(m) left join month_data d on d.fiscal_month=g.m
 ),
 cat_data as (
   select category,sum(collection_amount) filter(where fiscal_year=fy) current_amount,
     sum(collection_amount) filter(where fiscal_year=prev) prior_amount
   from kept group by category
 ),
 categories as (
   select jsonb_agg(jsonb_build_object('category',category,'current',coalesce(current_amount,0),'prior',coalesce(prior_amount,0),
     'growth',case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end,
     'share',case when (select coalesce(sum(collection_amount),0) from kept where fiscal_year=fy and action<>'omit')<>0
       then round(current_amount/(select sum(collection_amount) from kept where fiscal_year=fy and action<>'omit')*100,2) else null end)
     order by current_amount desc nulls last) v from cat_data
 ),
 head_data as (
   select revenue_head_id code,max(description) description,max(category) category,
     sum(collection_amount) filter(where fiscal_year=fy) current_amount,
     sum(collection_amount) filter(where fiscal_year=prev) prior_amount
   from kept group by revenue_head_id
 ),
 heads as (
   select jsonb_agg(jsonb_build_object('code',code,'description',description,'category',category,
     'current',coalesce(current_amount,0),'prior',coalesce(prior_amount,0),
     'change',coalesce(current_amount,0)-coalesce(prior_amount,0),
     'growth',case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end,
     'share',case when (select coalesce(sum(collection_amount),0) from kept where fiscal_year=fy)<>0
       then round(current_amount/(select sum(collection_amount) from kept where fiscal_year=fy)*100,2) else null end)
     order by current_amount desc nulls last) v from (select * from head_data order by current_amount desc nulls last limit 100) h
 ),
 kpis as (
   select coalesce(sum(collection_amount) filter(where fiscal_year=fy),0) net,
     coalesce(sum(greatest(collection_amount,0)) filter(where fiscal_year=fy),0) gross,
     coalesce(sum(abs(least(collection_amount,0))) filter(where fiscal_year=fy),0) adjustments,
     count(*) filter(where fiscal_year=fy) records,
     count(distinct revenue_head_id) filter(where fiscal_year=fy) active_heads,
     coalesce(sum(collection_amount) filter(where fiscal_year=prev),0) prior_net
   from kept
 ),
 concentration as (
   select coalesce(sum(amount) filter(where rn<=5),0) top5,
     coalesce(sum(amount) filter(where rn<=10),0) top10
   from (select revenue_head_id,sum(collection_amount) amount,row_number() over(order by sum(collection_amount) desc) rn
     from kept where fiscal_year=fy group by revenue_head_id) x
 )
 select jsonb_build_object('ready',true,'fiscal_year',fy,'previous_fiscal_year',prev,
   'net_collection',(select net from kpis),'gross_collection',(select gross from kpis),
   'negative_adjustments',(select adjustments from kpis),'records',(select records from kpis),
   'active_heads',(select active_heads from kpis),'prior_net_collection',(select prior_net from kpis),
   'yoy_growth',case when (select prior_net from kpis)<>0 then round(((select net from kpis)/(select prior_net from kpis)-1)*100,2) else null end,
   'top5_share',case when (select net from kpis)<>0 then round((select top5 from concentration)/(select net from kpis)*100,2) else null end,
   'top10_share',case when (select net from kpis)<>0 then round((select top10 from concentration)/(select net from kpis)*100,2) else null end,
   'annual',(select v from annual),'monthly',(select v from monthly),
   'categories',(select v from categories),'heads',(select v from heads)
 ) into outj;
 return outj;
end $$;
revoke all on function public.get_revenue_intelligence(text) from public,anon;
grant execute on function public.get_revenue_intelligence(text) to authenticated;
