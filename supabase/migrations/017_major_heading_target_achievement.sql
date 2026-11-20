-- Executive overview: YTD target achievement for the four principal tax headings.
create or replace function public.get_major_heading_target_achievement(p_fiscal_year text)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare cutoff_day integer; cutoff_month integer; outj jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select max(c.fiscal_day),max(c.fiscal_month)
 into cutoff_day,cutoff_month
 from public.revenue_daily r
 join public.fiscal_calendar c on c.gregorian_date=r.collection_date
 where c.fiscal_year=p_fiscal_year;
 if cutoff_day is null then
   return jsonb_build_object('fiscal_year',p_fiscal_year,'cutoff_day',null,'headings','[]'::jsonb);
 end if;
 with categories(name) as (
   values ('VAT'),('Excise'),('Income Tax'),('Customs')
 ),
 actuals as (
   select coalesce(rule.classification,'Unclassified') category,
          sum(r.collection_amount) actual
   from public.revenue_daily r
   join public.fiscal_calendar c on c.gregorian_date=r.collection_date
   left join lateral (
     select classification,action
     from public.revenue_classification_rules
     where is_active and r.revenue_head_id like code_prefix||'%'
     order by length(code_prefix) desc limit 1
   ) rule on true
   where c.fiscal_year=p_fiscal_year and c.fiscal_day<=cutoff_day
     and coalesce(rule.action,'classify')<>'omit'
   group by coalesce(rule.classification,'Unclassified')
 ),
 targets as (
   select coalesce(rule.classification,'Unclassified') category,
          sum(t.target_amount) target
   from public.monthly_targets t
   left join lateral (
     select classification,action
     from public.revenue_classification_rules
     where is_active and t.revenue_head_id like code_prefix||'%'
     order by length(code_prefix) desc limit 1
   ) rule on true
   where t.fiscal_year=p_fiscal_year and t.fiscal_month<=cutoff_month
     and coalesce(rule.action,'classify')<>'omit'
     and t.revenue_head_id is not null
   group by coalesce(rule.classification,'Unclassified')
 )
 select jsonb_build_object(
   'fiscal_year',p_fiscal_year,'cutoff_day',cutoff_day,'cutoff_month',cutoff_month,
   'headings',coalesce(jsonb_agg(jsonb_build_object(
     'name',c.name,'actual',coalesce(a.actual,0),'target',coalesce(t.target,0),
     'achievement',case when coalesce(t.target,0)>0 then a.actual/t.target*100 else null end
   ) order by case c.name when 'VAT' then 1 when 'Excise' then 2 when 'Income Tax' then 3 else 4 end),'[]'::jsonb)
 ) into outj
 from categories c
 left join actuals a on lower(a.category)=lower(c.name)
 left join targets t on lower(t.category)=lower(c.name);
 return outj;
end;
$$;
revoke all on function public.get_major_heading_target_achievement(text) from public,anon;
grant execute on function public.get_major_heading_target_achievement(text) to authenticated;
