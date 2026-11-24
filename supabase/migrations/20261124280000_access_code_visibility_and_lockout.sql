-- Admin visibility for viewer access codes and server-side 10-minute lockouts.
-- Failed attempts are tracked independently by browser identifier and forwarded client IP.
alter table public.viewer_access_codes add column if not exists code_value text;

create table if not exists public.viewer_access_lockouts (
  lock_key text primary key,
  lock_type text not null check (lock_type in ('browser','ip')),
  failed_attempts integer not null default 0,
  blocked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.viewer_access_lockouts enable row level security;

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
      insert into public.viewer_access_codes(code_hash, code_value, created_by)
      values (encode(digest(v_code, 'sha256'), 'hex'), v_code, auth.uid())
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
      'id', id, 'code', code_value, 'created_at', created_at, 'expires_at', expires_at,
      'max_uses', max_uses, 'use_count', use_count, 'revoked_at', revoked_at
    ) order by created_at desc)
    from public.viewer_access_codes
  ), '[]'::jsonb);
end;
$$;

create or replace function public.redeem_viewer_access_code(p_code text, p_browser_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_code public.viewer_access_codes%rowtype;
  v_uid uuid := auth.uid();
  v_headers jsonb;
  v_ip text;
  v_ip_key text;
  v_browser_key text;
  v_blocked timestamptz;
  v_bad boolean;
begin
  if v_uid is null then raise exception 'Sign-in is required before redeeming a code'; end if;
  if not coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then
    raise exception 'This access code can only be redeemed from the viewer sign-in screen';
  end if;
  if p_browser_id is null then
    return jsonb_build_object('ok', false, 'message', 'Browser identification is unavailable. Refresh the page and try again.');
  end if;

  -- Supabase/PostgREST forwards the client IP in request headers.
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then
    v_headers := '{}'::jsonb;
  end;
  v_ip := coalesce(v_headers->>'cf-connecting-ip', v_headers->>'x-real-ip', split_part(coalesce(v_headers->>'x-forwarded-for',''), ',', 1));
  v_ip := nullif(trim(v_ip), '');
  v_browser_key := encode(digest('browser:' || p_browser_id::text, 'sha256'), 'hex');
  if v_ip is not null then
    v_ip_key := encode(digest('ip:' || v_ip, 'sha256'), 'hex');
  end if;

  -- Serialize attempts for both identifiers to avoid concurrent bypasses.
  perform pg_advisory_xact_lock(hashtextextended(v_browser_key, 0));
  if v_ip_key is not null then perform pg_advisory_xact_lock(hashtextextended(v_ip_key, 0)); end if;

  select max(blocked_until) into v_blocked
  from public.viewer_access_lockouts
  where lock_key in (v_browser_key, v_ip_key)
    and blocked_until > now();
  if v_blocked is not null then
    return jsonb_build_object('ok', false, 'blocked', true, 'retry_after', v_blocked,
      'message', 'Too many incorrect codes. This browser and IP address are blocked for 10 minutes.');
  end if;

  select * into v_code
  from public.viewer_access_codes
  where code_hash = encode(digest(coalesce(p_code,''), 'sha256'), 'hex')
  for update;

  v_bad := p_code is null or p_code !~ '^[0-9]{6}$'
    or not found
    or v_code.revoked_at is not null
    or v_code.expires_at <= now()
    or v_code.use_count >= v_code.max_uses;

  if v_bad then
    insert into public.viewer_access_lockouts(lock_key,lock_type,failed_attempts,blocked_until,updated_at)
    values (v_browser_key,'browser',1,null,now())
    on conflict (lock_key) do update set
      failed_attempts=case when public.viewer_access_lockouts.blocked_until is not null and public.viewer_access_lockouts.blocked_until <= now() then 1 else public.viewer_access_lockouts.failed_attempts+1 end,
      blocked_until=case when (case when public.viewer_access_lockouts.blocked_until is not null and public.viewer_access_lockouts.blocked_until <= now() then 1 else public.viewer_access_lockouts.failed_attempts+1 end)>=5 then now()+interval '10 minutes' else null end,
      updated_at=now();

    if v_ip_key is not null then
      insert into public.viewer_access_lockouts(lock_key,lock_type,failed_attempts,blocked_until,updated_at)
      values (v_ip_key,'ip',1,null,now())
      on conflict (lock_key) do update set
        failed_attempts=case when public.viewer_access_lockouts.blocked_until is not null and public.viewer_access_lockouts.blocked_until <= now() then 1 else public.viewer_access_lockouts.failed_attempts+1 end,
        blocked_until=case when (case when public.viewer_access_lockouts.blocked_until is not null and public.viewer_access_lockouts.blocked_until <= now() then 1 else public.viewer_access_lockouts.failed_attempts+1 end)>=5 then now()+interval '10 minutes' else null end,
        updated_at=now();
    end if;
    return jsonb_build_object('ok', false, 'message',
      case when (select blocked_until > now() from public.viewer_access_lockouts where lock_key=v_browser_key)
        then 'Five incorrect attempts. This browser and IP address are blocked for 10 minutes.'
        else 'The code is invalid, expired, revoked or fully used.' end);
  end if;

  update public.viewer_access_codes set use_count=use_count+1 where id=v_code.id;
  insert into public.viewer_access_grants(user_id,code_id)
  values(v_uid,v_code.id)
  on conflict(user_id) do update set code_id=excluded.code_id,granted_at=now();

  insert into public.profiles(id,display_name,role)
  values(v_uid,'Code-based viewer','viewer')
  on conflict(id) do update set display_name='Code-based viewer',role='viewer';

  delete from public.viewer_access_attempts where user_id=v_uid;
  delete from public.viewer_access_lockouts where lock_key in (v_browser_key,v_ip_key);
  return jsonb_build_object('ok',true);
end;
$$;

revoke all on function public.redeem_viewer_access_code(text) from public, anon, authenticated;
revoke all on function public.redeem_viewer_access_code(text,uuid) from public, anon;
grant execute on function public.redeem_viewer_access_code(text,uuid) to authenticated;
revoke all on function public.list_viewer_access_codes() from public, anon;
grant execute on function public.list_viewer_access_codes() to authenticated;
revoke all on function public.create_viewer_access_code() from public, anon;
grant execute on function public.create_viewer_access_code() to authenticated;
