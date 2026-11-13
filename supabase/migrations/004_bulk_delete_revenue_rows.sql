-- Revenue Intelligence v4: controlled bulk deletion of selected collection records
create or replace function public.bulk_delete_revenue_rows(p_ids bigint[])
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  n integer := 0;
  requested integer := coalesce(cardinality(p_ids),0);
  actor_email text;
begin
  if not public.is_editor() then
    raise exception 'Insufficient permission';
  end if;
  if requested = 0 then
    return jsonb_build_object('deleted',0,'requested',0);
  end if;
  if requested > 5000 then
    raise exception 'A maximum of 5,000 rows can be deleted in one operation';
  end if;
  select email into actor_email from auth.users where id=auth.uid();
  delete from public.revenue_daily
   where id = any(p_ids);
  get diagnostics n = row_count;
  insert into public.audit_logs(actor_id,actor_email,action,entity_type,entity_id,details)
  values(auth.uid(),actor_email,'BULK_DELETE_REVENUE_ROWS','revenue_daily','selected_rows',
    jsonb_build_object('requested_ids',requested,'deleted_rows',n));
  return jsonb_build_object('deleted',n,'requested',requested);
end;
$$;
revoke all on function public.bulk_delete_revenue_rows(bigint[]) from public,anon;
grant execute on function public.bulk_delete_revenue_rows(bigint[]) to authenticated;
