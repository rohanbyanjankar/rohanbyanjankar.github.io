-- Add fiscal-year share and year-on-year growth to revenue-head treemap data.
create or replace function public.get_revenue_category_heads(
  p_fiscal_year text,
  p_category text default 'Total'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare outj jsonb; prior_fy text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select max(fiscal_year) into prior_fy
  from (
    select distinct fiscal_year, split_part(fiscal_year,'/',1)::integer fy_start
    from public.fiscal_calendar
  ) y
  where fy_start < split_part(p_fiscal_year,'/',1)::integer;

  with base as (
    select c.fiscal_year,r.revenue_head_id code,
      coalesce(h.description,r.revenue_description,r.revenue_head_id) description,
      coalesce(rule.classification,'Unclassified') category,
      coalesce(rule.action,'classify') action,
      sum(r.collection_amount) amount
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date=r.collection_date
    left join public.revenue_heads h on h.code=r.revenue_head_id
    left join lateral (
      select classification,action from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix||'%'
      order by length(code_prefix) desc limit 1
    ) rule on true
    where c.fiscal_year in (p_fiscal_year,prior_fy)
    group by c.fiscal_year,r.revenue_head_id,h.description,r.revenue_description,rule.classification,rule.action
  ),
  current_heads as (
    select code,max(description) description,max(category) category,sum(amount) current
    from base
    where fiscal_year=p_fiscal_year and action<>'omit'
      and case
        when lower(p_category)='tax revenue' then lower(category) in ('vat','excise','customs','income tax','unclassified')
        when lower(p_category)='non-tax revenue' then lower(category) in ('interest and dividends','royalty')
        when lower(p_category)='total' then true
        else lower(category)=lower(p_category)
      end
    group by code
    having sum(amount)>0
  ),
  prior_heads as (
    select code,sum(amount) prior_amount
    from base
    where fiscal_year=prior_fy and action<>'omit'
      and case
        when lower(p_category)='tax revenue' then lower(category) in ('vat','excise','customs','income tax','unclassified')
        when lower(p_category)='non-tax revenue' then lower(category) in ('interest and dividends','royalty')
        when lower(p_category)='total' then true
        else lower(category)=lower(p_category)
      end
    group by code
  ),
  combined as (
    select ch.*,coalesce(ph.prior_amount,0) prior_amount
    from current_heads ch left join prior_heads ph using(code)
  ),
  totals as (select sum(current) total_current from combined)
  select coalesce(jsonb_agg(jsonb_build_object(
    'code',c.code,'description',c.description,'category',c.category,
    'current',c.current,'prior',c.prior_amount,
    'share',case when t.total_current>0 then c.current/t.total_current*100 else 0 end,
    'growth',case when c.prior_amount>0 then (c.current/c.prior_amount-1)*100 else null end
  ) order by c.current desc),'[]'::jsonb)
  into outj from combined c cross join totals t;

  return jsonb_build_object('fiscal_year',p_fiscal_year,'previous_fiscal_year',prior_fy,'heads',coalesce(outj,'[]'::jsonb));
end;
$$;

revoke all on function public.get_revenue_category_heads(text,text) from public,anon;
grant execute on function public.get_revenue_category_heads(text,text) to authenticated;
