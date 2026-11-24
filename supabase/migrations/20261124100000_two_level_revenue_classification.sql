-- Two-level revenue classification, additive and backward-compatible.
-- Existing classification values are copied to Classification 2.
-- The legacy classification column remains synchronized for older RPCs and clients.

alter table public.revenue_classification_rules
  add column if not exists classification1 text,
  add column if not exists classification2 text;

update public.revenue_classification_rules
set classification2 = coalesce(nullif(trim(classification2), ''), nullif(trim(classification), ''))
where classification2 is null or trim(classification2) = '';

create or replace function public.sync_revenue_rule_classifications()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op = 'INSERT' then
    new.classification2 := coalesce(nullif(trim(new.classification2), ''), nullif(trim(new.classification), ''));
    new.classification := new.classification2;
  else
    if new.classification2 is distinct from old.classification2 then
      new.classification := new.classification2;
    elsif new.classification is distinct from old.classification then
      new.classification2 := new.classification;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_revenue_rule_classifications on public.revenue_classification_rules;
create trigger trg_sync_revenue_rule_classifications
before insert or update of classification, classification2
on public.revenue_classification_rules
for each row execute function public.sync_revenue_rule_classifications();

-- Detailed and broad category aggregates for the Revenue Intelligence workspace.
create or replace function public.get_revenue_classification_breakdown(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  fy text;
  prev text;
  outj jsonb;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if not public.is_editor() and public.current_user_role() <> 'viewer' then
    raise exception 'Insufficient permission';
  end if;

  select fiscal_year into fy
  from public.fiscal_calendar
  where fiscal_year = p_fiscal_year
  order by gregorian_date desc limit 1;
  if fy is null then
    return jsonb_build_object('ready', false, 'message', 'Fiscal year not found in fiscal calendar.');
  end if;
  prev := public.previous_fiscal_year(fy);

  with base as (
    select
      r.revenue_head_id as code,
      coalesce(h.description, r.revenue_description, r.revenue_head_id) as description,
      c.fiscal_year,
      r.collection_amount,
      coalesce(nullif(trim(rule.classification1), ''), 'Unclassified') as classification1,
      coalesce(nullif(trim(rule.classification2), ''), nullif(trim(rule.classification), ''), 'Unclassified') as classification2,
      coalesce(rule.action, 'classify') as action
    from public.revenue_daily r
    join public.fiscal_calendar c on c.gregorian_date = r.collection_date
    left join public.revenue_heads h on h.code = r.revenue_head_id
    left join lateral (
      select classification1, classification2, classification, action
      from public.revenue_classification_rules
      where is_active and r.revenue_head_id like code_prefix || '%'
      order by length(code_prefix) desc
      limit 1
    ) rule on true
    where c.fiscal_year in (fy, prev)
  ),
  kept as (select * from base where action <> 'omit'),
  cat1_raw as (
    select classification1 as category,
      sum(collection_amount) filter (where fiscal_year=fy) current_amount,
      sum(collection_amount) filter (where fiscal_year=prev) prior_amount
    from kept group by classification1
  ),
  cat2_raw as (
    select classification2 as category,
      sum(collection_amount) filter (where fiscal_year=fy) current_amount,
      sum(collection_amount) filter (where fiscal_year=prev) prior_amount
    from kept group by classification2
  ),
  cats1 as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'category', category, 'current', coalesce(current_amount,0), 'prior', coalesce(prior_amount,0),
      'growth', case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end,
      'share', case when (select coalesce(sum(collection_amount),0) from kept where fiscal_year=fy)<>0
        then round(current_amount/(select sum(collection_amount) from kept where fiscal_year=fy)*100,2) else null end
    ) order by current_amount desc nulls last), '[]'::jsonb) value
    from cat1_raw
  ),
  cats2 as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'category', category, 'current', coalesce(current_amount,0), 'prior', coalesce(prior_amount,0),
      'growth', case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end,
      'share', case when (select coalesce(sum(collection_amount),0) from kept where fiscal_year=fy)<>0
        then round(current_amount/(select sum(collection_amount) from kept where fiscal_year=fy)*100,2) else null end
    ) order by current_amount desc nulls last), '[]'::jsonb) value
    from cat2_raw
  ),
  head_raw as (
    select code, max(description) description,
      max(classification1) classification1, max(classification2) classification2,
      sum(collection_amount) filter(where fiscal_year=fy) current_amount,
      sum(collection_amount) filter(where fiscal_year=prev) prior_amount
    from kept group by code
  ),
  head_json as (
    select coalesce(jsonb_agg(jsonb_build_object(
      'code',code,'description',description,
      'classification1',classification1,'classification2',classification2,
      'current',coalesce(current_amount,0),'prior',coalesce(prior_amount,0),
      'change',coalesce(current_amount,0)-coalesce(prior_amount,0),
      'growth',case when coalesce(prior_amount,0)<>0 then round((current_amount/prior_amount-1)*100,2) else null end
    ) order by current_amount desc nulls last),'[]'::jsonb) value
    from (select * from head_raw order by current_amount desc nulls last limit 5000) h
  )
  select jsonb_build_object(
    'ready',true,'fiscal_year',fy,'previous_fiscal_year',prev,
    'categories_classification1',(select value from cats1),
    'categories_classification2',(select value from cats2),
    'heads',(select value from head_json)
  ) into outj;
  return outj;
end;
$$;

revoke all on function public.get_revenue_classification_breakdown(text) from public, anon;
grant execute on function public.get_revenue_classification_breakdown(text) to authenticated;
