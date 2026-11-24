-- Import-linked tax revenue analysis based on Nepali revenue descriptions.
-- Uses the explicit Nepali keyword "आयात" in revenue_description. It does not
-- assume that all VAT, excise or customs collections are import-based.
create or replace function public.get_import_linked_tax_analysis(p_fiscal_year text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_fy text; v_prev text; v_cutoff_day integer; v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select c.fiscal_year into v_fy from public.fiscal_calendar c
 where trim(c.fiscal_year)=trim(p_fiscal_year) order by c.gregorian_date desc limit 1;
 if v_fy is null then return jsonb_build_object('ready',false,'message','Selected fiscal year was not found in the fiscal calendar.'); end if;
 select max(c.fiscal_day) into v_cutoff_day from public.revenue_daily r
 join public.fiscal_calendar c on c.gregorian_date=r.collection_date where trim(c.fiscal_year)=trim(v_fy);
 if v_cutoff_day is null then return jsonb_build_object('ready',false,'message','No revenue observations were found for the selected fiscal year.'); end if;
 v_prev:=public.previous_fiscal_year(v_fy);
 with classified as (
  select c.fiscal_year,c.fiscal_day,r.revenue_head_id code,
   coalesce(r.revenue_description,h.description,r.revenue_head_id) description,r.collection_amount,
   lower(trim(coalesce(nullif(rule.classification1,''),'Unclassified'))) class1,
   lower(trim(coalesce(nullif(rule.classification2,''),nullif(rule.classification,''),'Unclassified'))) class2,
   coalesce(rule.action,'classify') action,coalesce(r.revenue_description,'') source_description
  from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  left join public.revenue_heads h on h.code=r.revenue_head_id
  left join lateral (select classification1,classification2,classification,action
   from public.revenue_classification_rules where is_active and r.revenue_head_id like code_prefix||'%'
   order by length(code_prefix) desc limit 1) rule on true
  where (trim(c.fiscal_year)=trim(v_fy) or trim(c.fiscal_year)=trim(v_prev))
   and c.fiscal_day<=v_cutoff_day and coalesce(rule.action,'classify')<>'omit'
 ),
 matched as (
  select *,case
   when class1 in ('vat','value added tax') then 'VAT on imports'
   when class1 in ('excise','excise duty') then 'Excise on imports'
   when class1 in ('customs duty','customs','custom duty') then 'Customs duty on imports'
   else initcap(class1) end tax_label
  from classified where source_description ilike '%आयात%'
   and class1 in ('vat','value added tax','excise','excise duty','customs duty','customs','custom duty')
 ),
 totals as (
  select coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_import,
   coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_import,
   count(*) filter(where trim(fiscal_year)=trim(v_fy))::integer matched_records,
   count(distinct code) filter(where trim(fiscal_year)=trim(v_fy))::integer matched_heads from matched
 ),
 tax_totals as (
  select coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_tax,
   coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_tax
  from classified where class2 in ('tax revenue','tax revenues')
 ),
 category_raw as (
  select tax_label,coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_amount,
   coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_amount
  from matched group by tax_label
 ),
 category_json as (
  select coalesce(jsonb_agg(jsonb_build_object('tax',tax_label,'current',current_amount,'prior',prior_amount,
   'change',current_amount-prior_amount,'growth',case when prior_amount<>0 then round((current_amount/prior_amount-1)*100,2) else null end)
   order by current_amount desc),'[]'::jsonb) value from category_raw
 ),
 head_raw as (
  select code,max(description) description,max(tax_label) tax,
   coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_fy)),0)::numeric current_amount,
   coalesce(sum(collection_amount) filter(where trim(fiscal_year)=trim(v_prev)),0)::numeric prior_amount
  from matched group by code
 ),
 head_json as (
  select coalesce(jsonb_agg(jsonb_build_object('code',code,'description',description,'tax',tax,
   'current',current_amount,'prior',prior_amount,'change',current_amount-prior_amount)
   order by current_amount desc),'[]'::jsonb) value
  from (select * from head_raw order by current_amount desc limit 100) x
 )
 select jsonb_build_object('ready',true,'fiscal_year',v_fy,'previous_fiscal_year',v_prev,'cutoff_day',v_cutoff_day,
  'import_linked_total',(select current_import from totals),'prior_import_linked_total',(select prior_import from totals),
  'import_linked_change',(select current_import-prior_import from totals),
  'import_linked_growth',case when (select prior_import from totals)<>0 then round(((select current_import from totals)/(select prior_import from totals)-1)*100,2) else null end,
  'share_of_tax_revenue',case when (select current_tax from tax_totals)<>0 then round((select current_import from totals)/(select current_tax from tax_totals)*100,2) else null end,
  'prior_share_of_tax_revenue',case when (select prior_tax from tax_totals)<>0 then round((select prior_import from totals)/(select prior_tax from tax_totals)*100,2) else null end,
  'matched_records',(select matched_records from totals),'matched_heads',(select matched_heads from totals),
  'categories',(select value from category_json),'heads',(select value from head_json)) into v_result;
 return v_result;
end; $$;
revoke all on function public.get_import_linked_tax_analysis(text) from public,anon;
grant execute on function public.get_import_linked_tax_analysis(text) to authenticated;
