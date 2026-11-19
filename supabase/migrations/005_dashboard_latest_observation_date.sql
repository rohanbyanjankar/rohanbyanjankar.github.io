-- Revenue dashboard reporting cutoff: use the latest date with stored revenue observations.
-- This prevents the fiscal calendar's future dates from being presented as collection dates.
create or replace function public.get_revenue_dashboard(p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  fy text;
  prev text;
  last_day date;
  last_fiscal_day int;
  first_day date;
  outj jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select c.fiscal_year,c.gregorian_date,c.fiscal_day
    into fy,last_day,last_fiscal_day
  from public.fiscal_calendar c
  where (p_fiscal_year is null or c.fiscal_year=p_fiscal_year)
    and exists (
      select 1
      from public.revenue_daily r
      where r.collection_date=c.gregorian_date
    )
  order by c.gregorian_date desc
  limit 1;

  if fy is null then
    return jsonb_build_object(
      'ready',false,
      'message',case
        when exists(select 1 from public.fiscal_calendar)
          then 'No revenue observations are available for the selected fiscal year.'
        else 'Fiscal calendar has not been loaded.'
      end
    );
  end if;

  prev:=public.previous_fiscal_year(fy);
  select min(gregorian_date) into first_day
  from public.fiscal_calendar
  where fiscal_year=fy;

  with classified as (
    select r.collection_date,r.revenue_head_id,r.collection_amount,
      coalesce(rule.classification,'Unclassified') category,
      coalesce(rule.action,'classify') action,
      h.description
    from public.revenue_daily r
    join public.fiscal_calendar c
      on c.gregorian_date=r.collection_date and c.fiscal_year=fy
    left join public.revenue_heads h on h.code=r.revenue_head_id
    left join lateral (
      select classification,action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
    where r.collection_date<=last_day
  ),
  kept as (
    select * from classified where action<>'omit'
  ),
  prior as (
    select sum(r.collection_amount) v
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date=r.collection_date
    where c.fiscal_year=prev
      and c.fiscal_day<=last_fiscal_day
      and not exists (
        select 1
        from public.revenue_classification_rules q
        where q.is_active and q.action='omit'
          and r.revenue_head_id like q.code_prefix||'%'
      )
  ),
  kpi as (
    select
      coalesce(sum(collection_amount),0) ytd,
      coalesce(sum(collection_amount) filter(where collection_date=last_day),0) latest
    from kept
  ),
  targets as (
    select coalesce(sum(t.target_amount),0) v
    from public.monthly_targets t
    where t.fiscal_year=fy
      and t.fiscal_month<=(
        select fiscal_month
        from public.fiscal_calendar
        where gregorian_date=last_day
      )
      and (
        t.revenue_head_id is null
        or not exists (
          select 1
          from public.revenue_classification_rules q
          where q.is_active and q.action='omit'
            and t.revenue_head_id like q.code_prefix||'%'
        )
      )
  ),
  daily as (
    select jsonb_agg(
      jsonb_build_object('date',d,'amount',v) order by d
    ) v
    from (
      select collection_date d,sum(collection_amount) v
      from kept
      group by collection_date
      order by collection_date desc
      limit 90
    ) z
  ),
  cats as (
    select jsonb_agg(
      jsonb_build_object('name',category,'amount',v) order by v desc
    ) v
    from (
      select category,sum(collection_amount) v
      from kept
      group by category
      order by v desc
      limit 12
    ) z
  ),
  topheads as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'code',code,'description',description,
        'category',category,'amount',amount
      ) order by amount desc
    ),'[]'::jsonb) v
    from (
      select revenue_head_id code,
        max(description) description,
        max(category) category,
        sum(collection_amount) amount
      from kept
      group by revenue_head_id
      order by sum(collection_amount) desc
      limit 15
    ) z
  ),
  monthly as (
    select jsonb_agg(
      jsonb_build_object('month',m,'amount',coalesce(v,0)) order by m
    ) v
    from generate_series(1,12) as gs(m)
    left join (
      select c.fiscal_month m,sum(k.collection_amount) v
      from kept k
      join public.fiscal_calendar c on c.gregorian_date=k.collection_date
      group by c.fiscal_month
    ) x using(m)
  ),
  daily_fiscal as (
    select jsonb_agg(
      jsonb_build_object('day',fiscal_day,'amount',amount)
      order by fiscal_day
    ) v
    from (
      select c.fiscal_day,sum(k.collection_amount) amount
      from kept k
      join public.fiscal_calendar c on c.gregorian_date=k.collection_date
      group by c.fiscal_day
    ) z
  )
  select jsonb_build_object(
    'ready',true,
    'fiscal_year',fy,
    'previous_fiscal_year',prev,
    'as_of',last_day,
    'first_day',first_day,
    'nepali_date',(
      select nepali_date from public.fiscal_calendar
      where gregorian_date=last_day
    ),
    'fiscal_month',(
      select fiscal_month from public.fiscal_calendar
      where gregorian_date=last_day
    ),
    'fiscal_day',last_fiscal_day,
    'latest_day',(select latest from kpi),
    'ytd',(select ytd from kpi),
    'target_ytd',(select v from targets),
    'achievement',case
      when (select v from targets)>0
      then round((select ytd from kpi)/(select v from targets)*100,2)
      else null
    end,
    'prior_ytd',(select v from prior),
    'yoy_growth',case
      when coalesce((select v from prior),0)>0
      then round(((select ytd from kpi)/(select v from prior)-1)*100,2)
      else null
    end,
    'daily',(select v from daily),
    'daily_fiscal',(select v from daily_fiscal),
    'composition',(select v from cats),
    'top_heads',(select v from topheads),
    'monthly',(select v from monthly)
  ) into outj;

  return outj;
end $$;

revoke all on function public.get_revenue_dashboard(text) from public,anon;
grant execute on function public.get_revenue_dashboard(text) to authenticated;
