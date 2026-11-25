-- Make the revenue treemap use the current two-level classification rules.
-- Classification 1 is the broad heading (for example, Tax Revenue);
-- Classification 2 is the detailed heading (for example, VAT or Royalty).
-- Retain the legacy classification column as a backward-compatible fallback.

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
  prior_fy text;
  cutoff_day integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  prior_fy := public.previous_fiscal_year(p_fiscal_year);

  select max(c.fiscal_day) into cutoff_day
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date = r.collection_date
  where c.fiscal_year = p_fiscal_year;

  with base as (
    select
      c.fiscal_year,
      r.revenue_head_id code,
      coalesce(h.description, r.revenue_description, r.revenue_head_id) description,
      coalesce(
        nullif(trim(rule.classification2), ''),
        nullif(trim(rule.classification1), ''),
        nullif(trim(rule.classification), ''),
        'Unclassified'
      ) category,
      nullif(trim(rule.classification1), '') classification1,
      nullif(trim(rule.classification2), '') classification2,
      nullif(trim(rule.classification), '') legacy_classification,
      coalesce(rule.action, 'classify') action,
      sum(r.collection_amount) amount
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    left join public.revenue_heads h on h.code = r.revenue_head_id
    left join lateral (
      select rr.classification, rr.classification1, rr.classification2, rr.action
      from public.revenue_classification_rules rr
      where rr.is_active
        and r.revenue_head_id like rr.code_prefix || '%'
      order by length(rr.code_prefix) desc
      limit 1
    ) rule on true
    where c.fiscal_year in (p_fiscal_year, prior_fy)
      and (
        c.fiscal_year = p_fiscal_year
        or c.fiscal_day <= coalesce(cutoff_day, 0)
      )
    group by
      c.fiscal_year, r.revenue_head_id, h.description, r.revenue_description,
      rule.classification1, rule.classification2, rule.classification, rule.action
  ),
  current_heads as (
    select code, max(description) description, max(category) category, sum(amount) current
    from base
    where fiscal_year = p_fiscal_year
      and action <> 'omit'
      and case
        when lower(trim(p_category)) = 'tax revenue' then
          lower(coalesce(classification1, '')) = 'tax revenue'
          or lower(coalesce(classification2, '')) in ('vat','value added tax','excise','customs','customs duty','income tax','direct tax')
          or lower(coalesce(legacy_classification, '')) in ('vat','value added tax','excise','customs','customs duty','income tax','direct tax','tax revenue')
        when lower(trim(p_category)) in ('non-tax revenue','non tax revenue') then
          lower(coalesce(classification1, '')) in ('non-tax revenue','non tax revenue')
          or lower(coalesce(classification2, '')) in ('interest and dividends','interest','dividends','royalty')
          or lower(coalesce(legacy_classification, '')) in ('interest and dividends','interest','dividends','royalty','non-tax revenue','non tax revenue')
        when lower(trim(p_category)) = 'total' then true
        else
          lower(coalesce(classification1, '')) = lower(trim(p_category))
          or lower(coalesce(classification2, '')) = lower(trim(p_category))
          or lower(coalesce(legacy_classification, '')) = lower(trim(p_category))
      end
    group by code
    having sum(amount) > 0
  ),
  prior_heads as (
    select code, sum(amount) prior_amount
    from base
    where fiscal_year = prior_fy
      and action <> 'omit'
      and case
        when lower(trim(p_category)) = 'tax revenue' then
          lower(coalesce(classification1, '')) = 'tax revenue'
          or lower(coalesce(classification2, '')) in ('vat','value added tax','excise','customs','customs duty','income tax','direct tax')
          or lower(coalesce(legacy_classification, '')) in ('vat','value added tax','excise','customs','customs duty','income tax','direct tax','tax revenue')
        when lower(trim(p_category)) in ('non-tax revenue','non tax revenue') then
          lower(coalesce(classification1, '')) in ('non-tax revenue','non tax revenue')
          or lower(coalesce(classification2, '')) in ('interest and dividends','interest','dividends','royalty')
          or lower(coalesce(legacy_classification, '')) in ('interest and dividends','interest','dividends','royalty','non-tax revenue','non tax revenue')
        when lower(trim(p_category)) = 'total' then true
        else
          lower(coalesce(classification1, '')) = lower(trim(p_category))
          or lower(coalesce(classification2, '')) = lower(trim(p_category))
          or lower(coalesce(legacy_classification, '')) = lower(trim(p_category))
      end
    group by code
  ),
  combined as (
    select ch.*, coalesce(ph.prior_amount, 0) prior_amount
    from current_heads ch
    left join prior_heads ph using (code)
  ),
  totals as (select sum(current) total_current from combined)
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', c.code,
        'description', c.description,
        'category', c.category,
        'current', c.current,
        'prior', c.prior_amount,
        'share', case when t.total_current > 0 then c.current / t.total_current * 100 else 0 end,
        'growth', case when c.prior_amount > 0 then (c.current / c.prior_amount - 1) * 100 else null end
      )
      order by c.current desc
    ),
    '[]'::jsonb
  )
  into outj
  from combined c
  cross join totals t;

  return jsonb_build_object(
    'fiscal_year', p_fiscal_year,
    'previous_fiscal_year', prior_fy,
    'heads', coalesce(outj, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_revenue_category_heads(text, text) from public, anon;
grant execute on function public.get_revenue_category_heads(text, text) to authenticated;
