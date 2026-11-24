-- Server-side aggregation for the executive five-year comparison.
-- This avoids transferring every revenue_daily row to the browser.
create or replace function public.get_executive_five_year_comparison(
  p_fiscal_year text,
  p_cutoff_date date default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_fy text;
  v_start date;
  v_cutoff date;
  v_cutoff_day integer;
  v_years jsonb;
  v_rows jsonb;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select c.fiscal_year, min(c.gregorian_date)
    into v_fy, v_start
  from public.fiscal_calendar c
  where trim(c.fiscal_year) = trim(p_fiscal_year)
  group by c.fiscal_year;

  if v_fy is null then
    return jsonb_build_object(
      'ready', false,
      'message', 'Selected fiscal year was not found in fiscal_calendar.'
    );
  end if;

  if p_cutoff_date is not null then
    select max(c.gregorian_date)
      into v_cutoff
    from public.fiscal_calendar c
    where trim(c.fiscal_year) = trim(v_fy)
      and c.gregorian_date <= p_cutoff_date;
  else
    select max(r.collection_date)
      into v_cutoff
    from public.revenue_daily r
    join public.fiscal_calendar c
      on c.gregorian_date = r.collection_date
    where trim(c.fiscal_year) = trim(v_fy);
  end if;

  if v_cutoff is null then
    return jsonb_build_object(
      'ready', false,
      'message', 'No revenue observations found in the selected fiscal year or cutoff.'
    );
  end if;

  select c.fiscal_day
    into v_cutoff_day
  from public.fiscal_calendar c
  where trim(c.fiscal_year) = trim(v_fy)
    and c.gregorian_date = v_cutoff;

  with fiscal_years as (
    select c.fiscal_year, min(c.gregorian_date) as start_date
    from public.fiscal_calendar c
    group by c.fiscal_year
  ),
  chosen_years as (
    select fy.fiscal_year, fy.start_date
    from fiscal_years fy
    where fy.start_date <= v_start
    order by fy.start_date desc
    limit 5
  ),
  calendar_scope as (
    select c.gregorian_date, c.fiscal_year, c.fiscal_day
    from public.fiscal_calendar c
    join chosen_years y on y.fiscal_year = c.fiscal_year
    where c.fiscal_day <= v_cutoff_day
  ),
  classified as (
    select
      c.fiscal_year,
      coalesce(nullif(trim(rule.classification2), ''),
               nullif(trim(rule.classification), ''),
               'Unclassified') as classification2,
      coalesce(nullif(trim(rule.classification1), ''), 'Unclassified') as classification1,
      r.collection_amount
    from public.revenue_daily r
    join calendar_scope c on c.gregorian_date = r.collection_date
    left join lateral (
      select rr.classification1, rr.classification2, rr.classification, rr.action
      from public.revenue_classification_rules rr
      where rr.is_active
        and r.revenue_head_id like rr.code_prefix || '%'
      order by length(rr.code_prefix) desc
      limit 1
    ) rule on true
    where coalesce(rule.action, 'classify') <> 'omit'
  ),
  grouped_rows as (
    select fiscal_year, classification2, classification1,
           sum(collection_amount)::numeric as amount
    from classified
    group by fiscal_year, classification2, classification1
  )
  select
    coalesce(
      (select jsonb_agg(fiscal_year order by start_date desc)
       from chosen_years),
      '[]'::jsonb
    ),
    coalesce(
      (select jsonb_agg(
        jsonb_build_object(
          'fiscal_year', fiscal_year,
          'classification2', classification2,
          'classification1', classification1,
          'amount', amount
        )
        order by fiscal_year, classification2, classification1
      )
      from grouped_rows),
      '[]'::jsonb
    )
  into v_years, v_rows;

  v_result := jsonb_build_object(
    'ready', true,
    'fiscal_year', v_fy,
    'cutoff_date', v_cutoff,
    'cutoff_fiscal_day', v_cutoff_day,
    'years', v_years,
    'rows', v_rows
  );

  return v_result;
end;
$$;

revoke all on function public.get_executive_five_year_comparison(text, date) from public, anon;
grant execute on function public.get_executive_five_year_comparison(text, date) to authenticated;
