-- Prevent negative target amounts when prior-year net monthly collections
-- are negative or the growth assumption is below -100 percent.
-- Historical actuals remain signed and manual overrides remain protected.

create or replace function public.generate_monthly_targets(
  p_fiscal_year text,
  p_growth_percent numeric,
  p_revenue_head_id text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  prev text;
  n integer:=0;
  floored integer:=0;
begin
  if not public.is_editor() then
    raise exception 'Insufficient permission';
  end if;

  if p_growth_percent is null then
    raise exception 'Growth assumption is required';
  end if;

  prev:=public.previous_fiscal_year(p_fiscal_year);

  with actuals as (
    select c.fiscal_month,r.revenue_head_id,sum(r.collection_amount) actual
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date=r.collection_date
    where c.fiscal_year=prev
      and (p_revenue_head_id is null or r.revenue_head_id=p_revenue_head_id)
      and not exists(
        select 1 from public.revenue_classification_rules q
        where q.is_active and q.action='omit'
          and r.revenue_head_id like q.code_prefix||'%'
      )
    group by c.fiscal_month,r.revenue_head_id
  ),
  prepared as (
    select p_fiscal_year fiscal_year,a.fiscal_month,a.revenue_head_id,
      a.actual previous_year_actual,p_growth_percent growth_percent,
      greatest(0,round(a.actual*(1+p_growth_percent/100),2)) target_amount
    from actuals a
  ),
  up as (
    insert into public.monthly_targets(
      fiscal_year,fiscal_month,revenue_head_id,previous_year_actual,
      growth_percent,target_amount,is_override,updated_by
    )
    select fiscal_year,fiscal_month,revenue_head_id,previous_year_actual,
      growth_percent,target_amount,false,auth.uid()
    from prepared
    on conflict(fiscal_year,fiscal_month,revenue_head_id) do update
    set previous_year_actual=excluded.previous_year_actual,
      growth_percent=excluded.growth_percent,
      target_amount=case when monthly_targets.is_override
        then monthly_targets.target_amount else excluded.target_amount end,
      updated_by=auth.uid(),updated_at=now()
    returning target_amount,is_override
  )
  select count(*),count(*) filter(where target_amount=0 and not is_override)
  into n,floored
  from up;

  return jsonb_build_object(
    'generated',n,
    'previous_fiscal_year',prev,
    'zero_floor_count',floored,
    'note','Targets are floored at zero where the formula would produce a negative amount. Manual overrides are preserved.'
  );
end;
$$;

revoke all on function public.generate_monthly_targets(text,numeric,text) from public,anon;
grant execute on function public.generate_monthly_targets(text,numeric,text) to authenticated;
