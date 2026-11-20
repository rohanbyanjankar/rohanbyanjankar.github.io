-- Six-digit shared viewer access codes for the Revenue Intelligence beta.
-- Run this migration in the Supabase SQL Editor after the existing application migrations.

create table if not exists public.viewer_access_codes (
  id uuid primary key default gen_random_uuid(),
  code_hash text not null unique,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '30 days'),
  max_uses integer not null default 100 check (max_uses > 0),
  use_count integer not null default 0 check (use_count >= 0),
  revoked_at timestamptz
);

create table if not exists public.viewer_access_grants (
  user_id uuid primary key references auth.users(id) on delete cascade,
  code_id uuid not null references public.viewer_access_codes(id),
  granted_at timestamptz not null default now()
);

create table if not exists public.viewer_access_attempts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  failed_attempts integer not null default 0,
  blocked_until timestamptz
);

alter table public.viewer_access_codes enable row level security;
alter table public.viewer_access_grants enable row level security;
alter table public.viewer_access_attempts enable row level security;

create or replace function public.create_viewer_access_code()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code text;
  v_id uuid;
  v_expiry timestamptz;
  v_attempt integer := 0;
begin
  if not public.is_admin() then raise exception 'Administrator permission required'; end if;
  loop
    v_code := lpad(floor(random() * 1000000)::bigint::text, 6, '0');
    begin
      insert into public.viewer_access_codes(code_hash, created_by)
      values (encode(digest(v_code, 'sha256'), 'hex'), auth.uid())
      returning id, expires_at into v_id, v_expiry;
      exit;
    exception when unique_violation then
      v_attempt := v_attempt + 1;
      if v_attempt > 20 then raise exception 'Could not generate a unique access code. Try again.'; end if;
    end;
  end loop;
  return jsonb_build_object('id', v_id, 'code', v_code, 'expires_at', v_expiry, 'max_uses', 100);
end;
$$;

create or replace function public.list_viewer_access_codes()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Administrator permission required'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'created_at', created_at, 'expires_at', expires_at,
      'max_uses', max_uses, 'use_count', use_count, 'revoked_at', revoked_at
    ) order by created_at desc)
    from public.viewer_access_codes
  ), '[]'::jsonb);
end;
$$;

create or replace function public.revoke_viewer_access_code(p_code_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Administrator permission required'; end if;
  update public.viewer_access_codes set revoked_at = now()
  where id = p_code_id and revoked_at is null;
  if not found then raise exception 'Access code not found or already revoked'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.redeem_viewer_access_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code public.viewer_access_codes%rowtype;
  v_uid uuid := auth.uid();
  v_attempt public.viewer_access_attempts%rowtype;
begin
  if v_uid is null then raise exception 'Sign-in is required before redeeming a code'; end if;
  if not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'This access code can only be redeemed from the viewer sign-in screen';
  end if;
  select * into v_attempt from public.viewer_access_attempts where user_id = v_uid;
  if v_attempt.blocked_until is not null and v_attempt.blocked_until > now() then
    return jsonb_build_object('ok', false, 'message', 'Too many incorrect attempts. Try again later.');
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' then
    return jsonb_build_object('ok', false, 'message', 'Enter a valid six-digit code.');
  end if;

  select * into v_code
  from public.viewer_access_codes
  where code_hash = encode(digest(p_code, 'sha256'), 'hex')
  for update;

  if not found or v_code.revoked_at is not null or v_code.expires_at <= now() or v_code.use_count >= v_code.max_uses then
    insert into public.viewer_access_attempts(user_id, failed_attempts, blocked_until)
    values (v_uid, 1, null)
    on conflict (user_id) do update
      set failed_attempts = case when public.viewer_access_attempts.blocked_until is not null and public.viewer_access_attempts.blocked_until <= now() then 1 else public.viewer_access_attempts.failed_attempts + 1 end,
          blocked_until = case when public.viewer_access_attempts.failed_attempts >= 4 then now() + interval '15 minutes' else null end;
    return jsonb_build_object('ok', false, 'message', 'The code is invalid, expired, revoked or fully used.');
  end if;

  update public.viewer_access_codes set use_count = use_count + 1 where id = v_code.id;
  insert into public.viewer_access_grants(user_id, code_id)
  values (v_uid, v_code.id)
  on conflict (user_id) do update set code_id = excluded.code_id, granted_at = now();

  insert into public.profiles(id, display_name, role)
  values (v_uid, 'Code-based viewer', 'viewer')
  on conflict (id) do update set display_name = 'Code-based viewer', role = 'viewer';

  delete from public.viewer_access_attempts where user_id = v_uid;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.validate_viewer_access_session()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_ok boolean;
begin
  if auth.uid() is null then return jsonb_build_object('ok', false); end if;
  select exists (
    select 1
    from public.viewer_access_grants g
    join public.viewer_access_codes c on c.id = g.code_id
    where g.user_id = auth.uid()
      and c.revoked_at is null
      and c.expires_at > now()
      and c.use_count <= c.max_uses
  ) into v_ok;
  return jsonb_build_object('ok', v_ok);
end;
$$;

revoke all on function public.create_viewer_access_code() from public, anon;
revoke all on function public.list_viewer_access_codes() from public, anon;
revoke all on function public.revoke_viewer_access_code(uuid) from public, anon;
revoke all on function public.redeem_viewer_access_code(text) from public, anon;
revoke all on function public.validate_viewer_access_session() from public, anon;
grant execute on function public.create_viewer_access_code() to authenticated;
grant execute on function public.list_viewer_access_codes() to authenticated;
grant execute on function public.revoke_viewer_access_code(uuid) to authenticated;
grant execute on function public.redeem_viewer_access_code(text) to authenticated;
grant execute on function public.validate_viewer_access_session() to authenticated;
