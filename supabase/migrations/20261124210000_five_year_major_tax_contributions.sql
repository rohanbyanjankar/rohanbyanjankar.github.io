-- Five-year contribution of VAT, Income Tax, Customs duty and Excise.
-- Uses annual totals available in the selected five fiscal years. Partial years
-- are labelled as such by the frontend based on the latest recorded date.

create or replace function public.get_major_tax_head_contributions(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 with fy_rank as (
  select fiscal_year,min(gregorian_date) start_date,
   row_number() over(order by min(gregorian_date) desc) rn
  from public.fiscal_calendar
  where split_part(fiscal_year,'/',1)::integer <= split_part(p_fiscal_year,'/',1)::integer
  group by fiscal_year
 ),
 chosen as (select fiscal_year,start_date from fy_rank where rn<=5),
 classified as (
  select c.fiscal_year,r.collection_amount,
   lower(trim(coalesce(nullif(rule.classification1,''),'Unclassified'))) class1,
   lower(trim(coalesce(nullif(rule.classification2,''),nullif(rule.classification,''),'Unclassified'))) class2,
   coalesce(rule.action,'classify') action
  from public.revenue_daily r
  join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  join chosen fy on fy.fiscal_year=c.fiscal_year
  left join lateral (
   select classification1,classification2,classification,action
   from public.revenue_classification_rules
   where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc limit 1
  ) rule on true
 ),
 totals as (
  select f.fiscal_year,
   coalesce(sum(x.collection_amount) filter(where x.action<>'omit'),0)::numeric total_revenue,
   coalesce(sum(x.collection_amount) filter(where x.action<>'omit' and x.class2 in ('tax revenue','tax revenues')),0)::numeric total_tax
  from chosen f left join classified x on x.fiscal_year=f.fiscal_year
  group by f.fiscal_year
 ),
 heads as (
  select fiscal_year,
   case
    when class1 in ('vat','value added tax') then 'VAT'
    when class1 in ('income tax','income-tax') then 'Income Tax'
    when class1 in ('customs','customs duty','custom duty') then 'Customs duty'
    when class1 in ('excise','excise duty') then 'Excise'
   end head,
   sum(collection_amount)::numeric amount
  from classified
  where action<>'omit'
  group by fiscal_year,case
    when class1 in ('vat','value added tax') then 'VAT'
    when class1 in ('income tax','income-tax') then 'Income Tax'
    when class1 in ('customs','customs duty','custom duty') then 'Customs duty'
    when class1 in ('excise','excise duty') then 'Excise'
   end
 ),
 rows as (
  select f.fiscal_year,f.start_date,t.total_revenue,t.total_tax,
   coalesce(max(h.amount) filter(where h.head='VAT'),0)::numeric vat,
   coalesce(max(h.amount) filter(where h.head='Income Tax'),0)::numeric income_tax,
   coalesce(max(h.amount) filter(where h.head='Customs duty'),0)::numeric customs,
   coalesce(max(h.amount) filter(where h.head='Excise'),0)::numeric excise
  from chosen f join totals t using(fiscal_year)
  left join heads h using(fiscal_year)
  group by f.fiscal_year,f.start_date,t.total_revenue,t.total_tax
 )
 select jsonb_build_object('ready',true,'years',coalesce(jsonb_agg(jsonb_build_object(
  'fiscal_year',fiscal_year,'total_revenue',total_revenue,'total_tax_revenue',total_tax,
  'VAT',vat,'Income Tax',income_tax,'Customs duty',customs,'Excise',excise,
  'VAT_share_total',case when total_revenue<>0 then round(vat/total_revenue*100,2) else null end,
  'Income_Tax_share_total',case when total_revenue<>0 then round(income_tax/total_revenue*100,2) else null end,
  'Customs_share_total',case when total_revenue<>0 then round(customs/total_revenue*100,2) else null end,
  'Excise_share_total',case when total_revenue<>0 then round(excise/total_revenue*100,2) else null end,
  'VAT_share_tax',case when total_tax<>0 then round(vat/total_tax*100,2) else null end,
  'Income_Tax_share_tax',case when total_tax<>0 then round(income_tax/total_tax*100,2) else null end,
  'Customs_share_tax',case when total_tax<>0 then round(customs/total_tax*100,2) else null end,
  'Excise_share_tax',case when total_tax<>0 then round(excise/total_tax*100,2) else null end
 ) order by start_date),'[]'::jsonb)) into v_result from rows;
 return v_result;
end;
$$;
revoke all on function public.get_major_tax_head_contributions(text) from public,anon;
grant execute on function public.get_major_tax_head_contributions(text) to authenticated;
