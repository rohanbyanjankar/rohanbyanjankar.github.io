create extension if not exists pgcrypto;
create table if not exists public.profiles(id uuid primary key references auth.users(id) on delete cascade,display_name text,role text not null default 'viewer' check(role in('admin','editor','viewer')),created_at timestamptz default now());
create table if not exists public.fiscal_calendar(gregorian_date date primary key,nepali_date text not null,fiscal_year text not null,fiscal_month smallint not null check(fiscal_month between 1 and 12),fiscal_day smallint not null check(fiscal_day between 1 and 366));
create index if not exists fiscal_calendar_fy_idx on public.fiscal_calendar(fiscal_year,fiscal_month,fiscal_day);
create table if not exists public.revenue_heads(code text primary key,description text not null,parent_code text references public.revenue_heads(code),level smallint not null default 3 check(level between 1 and 4),notes text,government_tier text,is_active boolean not null default true,updated_at timestamptz default now());
create table if not exists public.upload_history(id uuid primary key default gen_random_uuid(),filename text not null,total_rows integer not null default 0,inserted_rows integer not null default 0,duplicate_rows integer not null default 0,error_rows integer not null default 0,status text not null default 'pending',uploaded_by text,created_at timestamptz default now());
create table if not exists public.revenue_daily(id bigint generated always as identity primary key,collection_date date not null,revenue_head_id text not null references public.revenue_heads(code),revenue_description text,collection_amount numeric(20,2) not null check(collection_amount>=0),upload_id uuid references public.upload_history(id),created_at timestamptz default now(),unique(collection_date,revenue_head_id));
create index if not exists revenue_daily_date_idx on public.revenue_daily(collection_date);
create index if not exists revenue_daily_head_date_idx on public.revenue_daily(revenue_head_id,collection_date);
create table if not exists public.annual_targets(id bigint generated always as identity primary key,fiscal_year text not null,revenue_head_id text,target_amount numeric(20,2) not null check(target_amount>=0),updated_by uuid references auth.users(id),updated_at timestamptz default now(),unique(fiscal_year,revenue_head_id));
create table if not exists public.monthly_targets(id bigint generated always as identity primary key,fiscal_year text not null,fiscal_month smallint not null check(fiscal_month between 1 and 12),revenue_head_id text,previous_year_actual numeric(20,2) not null default 0,growth_percent numeric(8,3) not null default 0,target_amount numeric(20,2) not null check(target_amount>=0),is_override boolean not null default false,formula text not null default 'previous_year_same_month_actual*(1+growth_percent/100)',updated_by uuid references auth.users(id),updated_at timestamptz default now(),unique(fiscal_year,fiscal_month,revenue_head_id));
create table if not exists public.audit_logs(id bigint generated always as identity primary key,actor_id uuid references auth.users(id),actor_email text,action text not null,entity_type text not null,entity_id text,details jsonb not null default '{}'::jsonb,created_at timestamptz default now());
create or replace function public.current_user_role() returns text language sql stable security definer set search_path=public as $$select coalesce((select role from public.profiles where id=auth.uid()),'viewer')$$;
create or replace function public.is_editor() returns boolean language sql stable security definer set search_path=public as $$select public.current_user_role() in('admin','editor')$$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$select public.current_user_role()='admin'$$;
alter table public.profiles enable row level security;alter table public.fiscal_calendar enable row level security;alter table public.revenue_heads enable row level security;alter table public.revenue_daily enable row level security;alter table public.annual_targets enable row level security;alter table public.monthly_targets enable row level security;alter table public.upload_history enable row level security;alter table public.audit_logs enable row level security;
create policy "profile self or admin read" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy "admin profile manage" on public.profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "calendar read" on public.fiscal_calendar for select to authenticated using(true);
create policy "calendar admin write" on public.fiscal_calendar for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "heads read" on public.revenue_heads for select to authenticated using(true);
create policy "heads editor write" on public.revenue_heads for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "daily read" on public.revenue_daily for select to authenticated using(true);
create policy "annual targets read" on public.annual_targets for select to authenticated using(true);
create policy "annual targets edit" on public.annual_targets for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "monthly targets read" on public.monthly_targets for select to authenticated using(true);
create policy "monthly targets edit" on public.monthly_targets for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "uploads read" on public.upload_history for select to authenticated using(public.is_editor());
create policy "uploads insert" on public.upload_history for insert to authenticated with check(public.is_editor());
create policy "uploads update" on public.upload_history for update to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "audit admin read" on public.audit_logs for select to authenticated using(public.is_admin());
create policy "audit self insert" on public.audit_logs for insert to authenticated with check(actor_id=auth.uid());
grant select on public.profiles,public.fiscal_calendar,public.revenue_heads,public.revenue_daily,public.annual_targets,public.monthly_targets,public.upload_history,public.audit_logs to authenticated;
grant insert,update on public.annual_targets,public.monthly_targets,public.upload_history to authenticated;grant insert on public.audit_logs to authenticated;
create or replace function public.import_revenue_batch(p_rows jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare n integer:=0; total integer:=jsonb_array_length(p_rows);
begin if not public.is_editor() then raise exception 'Insufficient permission';end if;
with parsed as(select (v->>'collection_date')::date d,v->>'revenue_head_id' code,v->>'revenue_description' descr,(v->>'collection_amount')::numeric amount from jsonb_array_elements(p_rows) v),
ins as(insert into public.revenue_daily(collection_date,revenue_head_id,revenue_description,collection_amount) select p.d,p.code,p.descr,p.amount from parsed p join public.revenue_heads h on h.code=p.code where p.amount>=0 on conflict(collection_date,revenue_head_id) do nothing returning 1) select count(*) into n from ins;
return jsonb_build_object('inserted',n,'duplicates',total-n,'invalid',0);end $$;
revoke all on function public.import_revenue_batch(jsonb) from public,anon;grant execute on function public.import_revenue_batch(jsonb) to authenticated;
create or replace function public.generate_monthly_targets(p_fiscal_year text,p_growth_percent numeric,p_revenue_head_id text default null) returns jsonb language plpgsql security definer set search_path=public as $$
declare prev text; n integer:=0;
begin if not public.is_editor() then raise exception 'Insufficient permission';end if;
prev:=(split_part(p_fiscal_year,'/',1)::int-1)::text||'/'||(split_part(p_fiscal_year,'/',2)::int-1)::text;
with actuals as(select c.fiscal_month,r.revenue_head_id,sum(r.collection_amount) actual from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date where c.fiscal_year=prev and(p_revenue_head_id is null or r.revenue_head_id=p_revenue_head_id) group by c.fiscal_month,r.revenue_head_id),
up as(insert into public.monthly_targets(fiscal_year,fiscal_month,revenue_head_id,previous_year_actual,growth_percent,target_amount,is_override,updated_by) select p_fiscal_year,a.fiscal_month,a.revenue_head_id,a.actual,p_growth_percent,round(a.actual*(1+p_growth_percent/100),2),false,auth.uid() from actuals a on conflict(fiscal_year,fiscal_month,revenue_head_id) do update set previous_year_actual=excluded.previous_year_actual,growth_percent=excluded.growth_percent,target_amount=case when monthly_targets.is_override then monthly_targets.target_amount else excluded.target_amount end,updated_by=auth.uid(),updated_at=now() returning 1) select count(*) into n from up;
return jsonb_build_object('generated',n,'previous_fiscal_year',prev);end $$;
revoke all on function public.generate_monthly_targets(text,numeric,text) from public,anon;grant execute on function public.generate_monthly_targets(text,numeric,text) to authenticated;
