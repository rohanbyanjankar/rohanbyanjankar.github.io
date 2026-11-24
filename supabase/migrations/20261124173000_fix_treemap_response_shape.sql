-- Correct the response contract expected by Revenue Analytics treemap.
-- The frontend reads result.data.heads, so return an object containing heads,
-- not a bare JSON array.

create or replace function public.get_revenue_category_heads(
  p_fiscal_year text,
  p_category text default 'Total'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  outj jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  with base as (
    select
      r.revenue_head_id as code,
      coalesce(h.description, r.revenue_description, r.revenue_head_id) as description,
      lower(trim(coalesce(nullif(rule.classification1, ''), 'Unclassified'))) as class1,
      lower(trim(coalesce(nullif(rule.classification2, ''), nullif(rule.classification, ''), 'Unclassified'))) as class2,
      coalesce(rule.action, 'classify') as action,
      sum(r.collection_amount)::numeric as amount
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    left join public.revenue_heads h on h.code = r.revenue_head_id
    left join lateral (
      select classification1, classification2, classification, action
      from public.revenue_classification_rules
      where is_active
        and r.revenue_head_id like code_prefix || '%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
    where trim(c.fiscal_year) = trim(p_fiscal_year)
    group by
      r.revenue_head_id, h.description, r.revenue_description,
      rule.classification1, rule.classification2, rule.classification, rule.action
  ),
  filtered as (
    select *
    from base
    where action <> 'omit'
      and amount > 0
      and case
        when lower(trim(p_category)) = 'total' then true
        when lower(trim(p_category)) = 'tax revenue' then class2 = 'tax revenue'
        when lower(trim(p_category)) = 'non-tax revenue' then class2 = 'non-tax revenue'
        else class1 = lower(trim(p_category))
          or class2 = lower(trim(p_category))
      end
  ),
  totals as (
    select sum(amount)::numeric as total_amount from filtered
  ),
  head_rows as (
    select
      code,
      description,
      class1,
      class2,
      amount,
      case
        when coalesce((select total_amount from totals), 0) > 0
        then round(amount / (select total_amount from totals) * 100, 2)
        else 0
      end as share
    from filtered
    order by amount desc
    limit 250
  )
  select jsonb_build_object(
    'heads',
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'code', code,
            'description', description,
            'category', initcap(class1),
            'classification1', initcap(class1),
            'classification2', initcap(class2),
            'current', amount,
            'share', share,
            'prior', 0,
            'growth', null
          )
          order by amount desc
        )
        from head_rows
      ),
      '[]'::jsonb
    )
  )
  into outj;

  return outj;
end;
$$;

revoke all on function public.get_revenue_category_heads(text, text) from public, anon;
grant execute on function public.get_revenue_category_heads(text, text) to authenticated;
