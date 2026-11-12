-- Revenue Intelligence v2: editable classification rules, safe imports and dashboard aggregates
drop function if exists public.import_revenue_batch(jsonb);
alter table public.profiles add column if not exists email text;

create table if not exists public.revenue_classification_rules (
  id bigint generated always as identity primary key,
  code_prefix text not null unique check (code_prefix ~ '^[0-9]+$'),
  classification text not null,
  action text not null default 'classify' check (action in ('classify','omit')),
  reason text,
  is_active boolean not null default true,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);
create index if not exists revenue_rules_prefix_idx on public.revenue_classification_rules(code_prefix);
alter table public.revenue_classification_rules enable row level security;
drop policy if exists "classification rules read" on public.revenue_classification_rules;
create policy "classification rules read" on public.revenue_classification_rules for select to authenticated using (true);
drop policy if exists "classification rules admin write" on public.revenue_classification_rules;
create policy "classification rules admin write" on public.revenue_classification_rules for all to authenticated using (public.is_admin()) with check (public.is_admin());
grant select on public.revenue_classification_rules to authenticated;
grant insert,update,delete on public.fiscal_calendar to authenticated;
grant insert,update,delete on public.revenue_classification_rules to authenticated;
grant usage,select on sequence public.revenue_classification_rules_id_seq to authenticated;

insert into public.revenue_classification_rules(code_prefix,classification,action,reason) values
('111','Income tax','classify','General classification rule'),
('3331','VAT','classify','General classification rule'),
('3333','Excise','classify','General classification rule'),
('1141','VAT','classify','General classification rule'),
('1142','Excise','classify','General classification rule'),
('115','Customs','classify','General classification rule'),
('11411','Omit','omit','Explicit exclusion in user-provided classification rules'),
('11421','Omit','omit','Explicit exclusion in user-provided classification rules'),
('14153','Omit','omit','Explicit exclusion in user-provided classification rules'),
('14154','Omit','omit','Explicit exclusion in user-provided classification rules'),
('14156','Omit','omit','Explicit exclusion in user-provided classification rules'),
('14158','Omit','omit','Explicit exclusion in user-provided classification rules'),
('1419','Non-tax revenue','classify','General classification rule'),
('1421','Non-tax revenue','classify','General classification rule'),
('1422','Non-tax revenue','classify','General classification rule'),
('1425','Non-tax revenue','classify','General classification rule'),
('1426','Non-tax revenue','classify','General classification rule'),
('1431','Non-tax revenue','classify','General classification rule'),
('1441','Non-tax revenue','classify','General classification rule'),
('1451','Non-tax revenue','classify','General classification rule'),
('1452','Non-tax revenue','classify','General classification rule'),
('1453','Non-tax revenue','classify','General classification rule'),
('15111','Omit','omit','Explicit exclusion in user-provided classification rules'),
('15112','Omit','omit','Explicit exclusion in user-provided classification rules'),
('15113','Omit','omit','Explicit exclusion in user-provided classification rules'),
('15114','Omit','omit','Explicit exclusion in user-provided classification rules'),
('32148','Omit','omit','Explicit exclusion in user-provided classification rules'),
('32149','Omit','omit','Explicit exclusion in user-provided classification rules'),
('3336','Royalty','classify','General classification rule'),
('3339','Non-tax revenue','classify','General classification rule'),
('131','Grants','classify','General classification rule'),
('132','Grants','classify','General classification rule'),
('134','Grants','classify','General classification rule'),
('141','Interest and Dividends','classify','General classification rule'),
('14159','Royalty','classify','Specific classification rule'),
('14152','Royalty','classify','Specific classification rule'),
('133','Grants','classify','General classification rule'),
('33341','Vehicle Tax','classify','Specific classification rule'),
('14157','Omit','omit','Explicit exclusion in user-provided classification rules'),
('15115','Omit','omit','Explicit exclusion in user-provided classification rules'),
('15116','Omit','omit','Explicit exclusion in user-provided classification rules'),
('3311','Omit','omit','VAT collection account: exclude to prevent double counting'),
('3313','Omit','omit','Excise collection account: exclude to prevent double counting')
on conflict(code_prefix) do update set classification=excluded.classification,action=excluded.action,reason=excluded.reason,updated_at=now();

-- Imports add unseen revenue-head metadata without overwriting an existing official description.
create or replace function public.import_revenue_batch(p_rows jsonb, p_upload_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare n integer:=0; dup integer:=0; bad integer:=0; total integer:=jsonb_array_length(p_rows);
begin
 if not public.is_editor() then raise exception 'Insufficient permission'; end if;
 with parsed as (
   select nullif(v->>'collection_date','')::date d,
          nullif(trim(v->>'revenue_head_id'),'') code,
          coalesce(nullif(v->>'revenue_description',''),nullif(v->>'revenue_desc',''),nullif(v->>'REVENUE_DESC','')) descr,
          replace(coalesce(v->>'collection_amount','0'),',','')::numeric amount
   from jsonb_array_elements(p_rows) v
 ), valid as (
   select * from parsed where d is not null and code is not null and amount >= 0
 ), heads as (
   insert into public.revenue_heads(code,description,level)
   select distinct code,coalesce(descr,code),greatest(1,least(4,length(code)-1))
   from valid on conflict(code) do nothing
 ), ins as (
   insert into public.revenue_daily(collection_date,revenue_head_id,revenue_description,collection_amount,upload_id)
   select d,code,descr,amount,p_upload_id from valid cross join (select count(*) from heads) dependency
   on conflict(collection_date,revenue_head_id) do nothing returning 1
 ) select count(*) into n from ins;
 select count(*) into bad from jsonb_array_elements(p_rows) v
 where coalesce(v->>'collection_date','') !~ '^\d{4}-\d{2}-\d{2}$'
    or coalesce(trim(v->>'revenue_head_id'),'')=''
    or replace(coalesce(v->>'collection_amount',''),',','') !~ '^\d+(\.\d+)?$';
 dup:=greatest(0,total-n-bad);
 return jsonb_build_object('inserted',n,'duplicates',dup,'invalid',bad);
end $$;
revoke all on function public.import_revenue_batch(jsonb,uuid) from public,anon;
grant execute on function public.import_revenue_batch(jsonb,uuid) to authenticated;

create or replace function public.previous_fiscal_year(p_fy text) returns text
language plpgsql immutable as $$
declare a text:=split_part(p_fy,'/',1); b text:=split_part(p_fy,'/',2);
begin
 if a !~ '^\d+$' or b !~ '^\d+$' then raise exception 'Fiscal year must look like 2082/83 or 2082/2083'; end if;
 if length(b)=2 then return (a::int-1)::text||'/'||lpad(((b::int-1+100)%100)::text,2,'0');
 else return (a::int-1)::text||'/'||(b::int-1)::text; end if;
end $$;

create or replace function public.generate_monthly_targets(p_fiscal_year text,p_growth_percent numeric,p_revenue_head_id text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare prev text; n integer:=0;
begin
 if not public.is_editor() then raise exception 'Insufficient permission'; end if;
 prev:=public.previous_fiscal_year(p_fiscal_year);
 with actuals as (
   select c.fiscal_month,r.revenue_head_id,sum(r.collection_amount) actual
   from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
   where c.fiscal_year=prev and (p_revenue_head_id is null or r.revenue_head_id=p_revenue_head_id)
     and not exists(select 1 from public.revenue_classification_rules q where q.is_active and q.action='omit' and r.revenue_head_id like q.code_prefix||'%')
   group by c.fiscal_month,r.revenue_head_id
 ), up as (
   insert into public.monthly_targets(fiscal_year,fiscal_month,revenue_head_id,previous_year_actual,growth_percent,target_amount,is_override,updated_by)
   select p_fiscal_year,a.fiscal_month,a.revenue_head_id,a.actual,p_growth_percent,round(a.actual*(1+p_growth_percent/100),2),false,auth.uid() from actuals a
   on conflict(fiscal_year,fiscal_month,revenue_head_id) do update
   set previous_year_actual=excluded.previous_year_actual,growth_percent=excluded.growth_percent,
       target_amount=case when monthly_targets.is_override then monthly_targets.target_amount else excluded.target_amount end,
       updated_by=auth.uid(),updated_at=now()
   returning 1
 ) select count(*) into n from up;
 return jsonb_build_object('generated',n,'previous_fiscal_year',prev);
end $$;
revoke all on function public.generate_monthly_targets(text,numeric,text) from public,anon;
grant execute on function public.generate_monthly_targets(text,numeric,text) to authenticated;

create or replace function public.get_revenue_dashboard(p_fiscal_year text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare fy text; prev text; last_day date; last_fiscal_day int; first_day date; outj jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select fiscal_year,gregorian_date,fiscal_day into fy,last_day,last_fiscal_day
 from public.fiscal_calendar
 where (p_fiscal_year is null or fiscal_year=p_fiscal_year)
 order by gregorian_date desc limit 1;
 if fy is null then return jsonb_build_object('ready',false,'message','Fiscal calendar has not been loaded.'); end if;
 prev:=public.previous_fiscal_year(fy);
 select min(gregorian_date) into first_day from public.fiscal_calendar where fiscal_year=fy;
 with classified as (
   select r.collection_date,r.revenue_head_id,r.collection_amount,
     coalesce(rule.classification,'Unclassified') category,
     coalesce(rule.action,'classify') action,
     h.description
   from public.revenue_daily r
   join public.fiscal_calendar c on c.gregorian_date=r.collection_date and c.fiscal_year=fy
   left join public.revenue_heads h on h.code=r.revenue_head_id
   left join lateral (
     select classification,action from public.revenue_classification_rules
     where is_active and r.revenue_head_id like code_prefix||'%'
     order by length(code_prefix) desc limit 1
   ) rule on true
   where r.collection_date<=last_day
 ), kept as (select * from classified where action<>'omit'),
 prior as (
   select sum(r.collection_amount) v from public.revenue_daily r
   join public.fiscal_calendar c on c.gregorian_date=r.collection_date
   where c.fiscal_year=prev and c.fiscal_day<=last_fiscal_day
     and not exists(select 1 from public.revenue_classification_rules q where q.is_active and q.action='omit' and r.revenue_head_id like q.code_prefix||'%')
 ),
 kpi as (
   select coalesce(sum(collection_amount),0) ytd,
     coalesce(sum(collection_amount) filter(where collection_date=last_day),0) latest
   from kept
 ),
 targets as (select coalesce(sum(target_amount),0) v from public.monthly_targets where fiscal_year=fy and fiscal_month<=(select fiscal_month from public.fiscal_calendar where gregorian_date=last_day)),
 daily as (select jsonb_agg(jsonb_build_object('date',d,'amount',v) order by d) v from (select collection_date d,sum(collection_amount) v from kept group by collection_date order by collection_date desc limit 90) z),
 cats as (select jsonb_agg(jsonb_build_object('name',category,'amount',v) order by v desc) v from (select category,sum(collection_amount) v from kept group by category order by v desc limit 12) z),
 topheads as (select coalesce(jsonb_agg(jsonb_build_object('code',code,'description',description,'category',category,'amount',amount) order by amount desc),'[]'::jsonb) v from (select revenue_head_id code,max(description) description,max(category) category,sum(collection_amount) amount from kept group by revenue_head_id order by sum(collection_amount) desc limit 15) z),
 monthly as (select jsonb_agg(jsonb_build_object('month',m,'amount',coalesce(v,0)) order by m) v from generate_series(1,12) as gs(m) left join (select c.fiscal_month m,sum(k.collection_amount) v from kept k join public.fiscal_calendar c on c.gregorian_date=k.collection_date group by c.fiscal_month) x using(m))
 select jsonb_build_object('ready',true,'fiscal_year',fy,'previous_fiscal_year',prev,'as_of',last_day,'first_day',first_day,'nepali_date',(select nepali_date from public.fiscal_calendar where gregorian_date=last_day),'fiscal_month',(select fiscal_month from public.fiscal_calendar where gregorian_date=last_day),'fiscal_day',last_fiscal_day,
 'latest_day',(select latest from kpi),'ytd',(select ytd from kpi),'target_ytd',(select v from targets),'achievement',case when (select v from targets)>0 then round((select ytd from kpi)/(select v from targets)*100,2) else null end,
 'prior_ytd',(select v from prior),'yoy_growth',case when coalesce((select v from prior),0)>0 then round(((select ytd from kpi)/(select v from prior)-1)*100,2) else null end,
 'daily',(select v from daily),'composition',(select v from cats),'top_heads',(select v from topheads),'monthly',(select v from monthly)) into outj;
 return outj;
end $$;
revoke all on function public.get_revenue_dashboard(text) from public,anon;
grant execute on function public.get_revenue_dashboard(text) to authenticated;

-- Automatically provision newly authenticated users as viewers. The first administrator is promoted manually.
create or replace function public.handle_new_auth_user() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,display_name,email,role)
 values(new.id,coalesce(new.raw_user_meta_data->>'full_name',new.email),new.email,'viewer')
 on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
for each row execute procedure public.handle_new_auth_user();
grant select,insert,update,delete on public.profiles to authenticated;

update public.profiles p set email=u.email from auth.users u where p.id=u.id and p.email is null;
