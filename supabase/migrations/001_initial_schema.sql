-- Government Revenue Intelligence: initial Supabase schema
-- Apply in Supabase SQL Editor. All amounts are stored in NPR.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 display_name text,
 role text not null default 'viewer' check (role in ('admin','editor','viewer')),
 created_at timestamptz not null default now()
);
create table if not exists public.fiscal_calendar (
 gregorian_date date primary key,
 nepali_date text not null,
 fiscal_year text not null,
 fiscal_month smallint not null check (fiscal_month between 1 and 12),
 fiscal_day smallint not null check (fiscal_day between 1 and 366),
 created_at timestamptz not null default now()
);
create index if not exists fiscal_calendar_fy_idx on public.fiscal_calendar(fiscal_year,fiscal_month,fiscal_day);
create table if not exists public.revenue_heads (
 code text primary key,
 description text not null,
 parent_code text references public.revenue_heads(code),
 level smallint not null default 3 check(level between 1 and 4),
 notes text,
 government_tier text,
 is_active boolean not null default true,
 updated_at timestamptz not null default now()
);
create index if not exists revenue_heads_parent_idx on public.revenue_heads(parent_code);
create table if not exists public.revenue_daily (
 id bigint generated always as identity primary key,
 collection_date date not null,
 revenue_head_id text not null references public.revenue_heads(code),
 revenue_description text,
 collection_amount numeric(20,2) not null check(collection_amount >= 0),
 upload_id uuid,
 created_at timestamptz not null default now(),
 unique(collection_date,revenue_head_id)
);
create index if not exists revenue_daily_date_idx on public.revenue_daily(collection_date);
create index if not exists revenue_daily_head_date_idx on public.revenue_daily(revenue_head_id,collection_date);
create table if not exists public.annual_targets (
 id bigint generated always as identity primary key,
 fiscal_year text not null,
 revenue_head_id text,
 target_amount numeric(20,2) not null check(target_amount >= 0),
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now(),
 unique(fiscal_year,revenue_head_id)
);
create table if not exists public.monthly_targets (
 id bigint generated always as identity primary key,
 fiscal_year text not null,
 fiscal_month smallint not null check(fiscal_month between 1 and 12),
 revenue_head_id text,
 previous_year_actual numeric(20,2) not null default 0,
 growth_percent numeric(8,3) not null default 0,
 target_amount numeric(20,2) not null check(target_amount >= 0),
 is_override boolean not null default false,
 formula text not null default 'previous_year_same_month_actual*(1+growth_percent/100)',
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now(),
 unique(fiscal_year,fiscal_month,revenue_head_id)
);
create table if not exists public.upload_history (
 id uuid primary key default gen_random_uuid(),
 filename text not null,
 total_rows integer not null default 0,
 inserted_rows integer not null default 0,
 duplicate_rows integer not null default 0,
 error_rows integer not null default 0,
 status text not null default 'pending',
 uploaded_by text,
 created_at timestamptz not null default now()
);
alter table public.revenue_daily add column if not exists upload_id uuid references public.upload_history(id);
create table if not exists public.audit_logs (
 id bigint generated always as identity primary key,
 actor_id uuid references auth.users(id),
 actor_email text,
 action text not null,
 entity_type text not null,
 entity_id text,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create table if not exists public.dashboard_settings (
 key text primary key,
 value jsonb not null,
 updated_by uuid references auth.users(id),
 updated_at timestamptz not null default now()
);

create or replace function public.current_user_role()
returns text language sql stable security definer set search_path=public
as $$ select coalesce((select role from public.profiles where id=auth.uid()),'viewer') $$;
create or replace function public.is_editor()
returns boolean language sql stable security definer set search_path=public
as $$ select public.current_user_role() in ('admin','editor') $$;
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public
as $$ select public.current_user_role()='admin' $$;

alter table public.profiles enable row level security;
alter table public.fiscal_calendar enable row level security;
alter table public.revenue_heads enable row level security;
alter table public.revenue_daily enable row level security;
alter table public.annual_targets enable row level security;
alter table public.monthly_targets enable row level security;
alter table public.upload_history enable row level security;
alter table public.audit_logs enable row level security;
alter table public.dashboard_settings enable row level security;

create policy "profiles read self or admin" on public.profiles for select to authenticated using(id=auth.uid() or public.is_admin());
create policy "profiles admin manage" on public.profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "calendar authenticated read" on public.fiscal_calendar for select to authenticated using(true);
create policy "calendar admin manage" on public.fiscal_calendar for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "heads authenticated read" on public.revenue_heads for select to authenticated using(true);
create policy "heads editor manage" on public.revenue_heads for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "daily authenticated read" on public.revenue_daily for select to authenticated using(true);
create policy "targets authenticated read" on public.annual_targets for select to authenticated using(true);
create policy "annual targets editor manage" on public.annual_targets for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "monthly targets authenticated read" on public.monthly_targets for select to authenticated using(true);
create policy "monthly targets editor manage" on public.monthly_targets for all to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "uploads editor read" on public.upload_history for select to authenticated using(public.is_editor());
create policy "uploads editor create" on public.upload_history for insert to authenticated with check(public.is_editor());
create policy "uploads editor update" on public.upload_history for update to authenticated using(public.is_editor()) with check(public.is_editor());
create policy "audit admin read" on public.audit_logs for select to authenticated using(public.is_admin());
create policy "audit authenticated create" on public.audit_logs for insert to authenticated with check(actor_id=auth.uid());
create policy "settings authenticated read" on public.dashboard_settings for select to authenticated using(true);
create policy "settings admin manage" on public.dashboard_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());

-- Secure batch importer: only new (date, revenue-code) observations are inserted.
create or replace function public.import_revenue_batch(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_inserted integer:=0; v_input integer:=0; v_duplicates integer:=0; v_invalid integer:=0;
begin
 if not public.is_editor() then raise exception 'Insufficient permission'; end if;
 if jsonb_typeof(p_rows)<>'array' then raise exception 'Expected a JSON array'; end if;
 v_input:=jsonb_array_length(p_rows);
 with parsed as (
  select (x->>'collection_date')::date as d, x->>'revenue_head_id' as code,
         x->>'revenue_description' as descr, (x->>'collection_amount')::numeric as amount
  from jsonb_array_elements(p_rows) x
 ), valid as (
  select p.* from parsed p join public.revenue_heads h on h.code=p.code
  where p.d is not null and p.amount>=0
 ), ins as (
  insert into public.revenue_daily(collection_date,revenue_head_id,revenue_description,collection_amount)
  select d,code,descr,amount from valid
  on conflict(collection_date,revenue_head_id) do nothing returning 1
 ) select count(*) into v_inserted from ins;
 v_duplicates:=greatest(v_input-v_inserted,0);
 return jsonb_build_object('inserted',v_inserted,'duplicates',v_duplicates,'invalid',v_invalid);
end $$;
revoke all on function public.import_revenue_batch(jsonb) from public,anon;
grant execute on function public.import_revenue_batch(jsonb) to authenticated;

-- Generate monthly targets for a fiscal year using same-month prior-year actuals.
-- Fiscal year labels are assumed to be e.g. 2082/83. The previous label is inferred as 2081/82.
create or replace function public.generate_monthly_targets(
 p_fiscal_year text, p_growth_percent numeric, p_revenue_head_id text default null
) returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_prev_fy text; v_count integer:=0;
begin
 if not public.is_editor() then raise exception 'Insufficient permission'; end if;
 v_prev_fy:=split_part(p_fiscal_year,'/',1)::integer-1||'/'||split_part(p_fiscal_year,'/',2)::integer-1;
 with prev_month as (
  select c.fiscal_month,r.revenue_head_id,sum(r.collection_amount) actual
  from public.revenue_daily r join public.fiscal_calendar c on c.gregorian_date=r.collection_date
  where c.fiscal_year=v_prev_fy and (p_revenue_head_id is null or r.revenue_head_id=p_revenue_head_id)
  group by c.fiscal_month,r.revenue_head_id
 ), up as (
  insert into public.monthly_targets(fiscal_year,fiscal_month,revenue_head_id,previous_year_actual,growth_percent,target_amount,is_override,updated_by)
  select p_fiscal_year,p.fiscal_month,p.revenue_head_id,p.actual,p_growth_percent,
         round(p.actual*(1+p_growth_percent/100),2),false,auth.uid()
  from prev_month p
  on conflict(fiscal_year,fiscal_month,revenue_head_id) do update
   set previous_year_actual=excluded.previous_year_actual,growth_percent=excluded.growth_percent,
       target_amount=case when public.monthly_targets.is_override then public.monthly_targets.target_amount else excluded.target_amount end,
       updated_by=auth.uid(),updated_at=now()
  returning 1
 ) select count(*) into v_count from up;
 return jsonb_build_object('generated',v_count,'previous_fiscal_year',v_prev_fy);
end $$;
revoke all on function public.generate_monthly_targets(text,numeric,text) from public,anon;
grant execute on function public.generate_monthly_targets(text,numeric,text) to authenticated;

grant select on public.profiles,public.fiscal_calendar,public.revenue_heads,public.revenue_daily,public.annual_targets,public.monthly_targets,public.upload_history,public.audit_logs,public.dashboard_settings to authenticated;
grant insert,update on public.annual_targets,public.monthly_targets,public.upload_history to authenticated;
grant insert on public.audit_logs to authenticated;
