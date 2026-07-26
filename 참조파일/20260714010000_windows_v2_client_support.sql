begin;

-- Safe follow-up for databases where the v2 baseline was applied before
-- the Windows client gained automatic local-project provisioning.
create or replace function public.ensure_project(
  p_project_id uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_owner_id uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null or p_name is null or pg_catalog.btrim(p_name) = '' then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );
  select owner_id into v_owner_id
  from public.projects
  where project_id = p_project_id;

  if not found then
    insert into public.projects (project_id, owner_id, name)
    values (p_project_id, v_user_id, pg_catalog.btrim(p_name));
    insert into public.project_members (project_id, user_id, role)
    values (p_project_id, v_user_id, 'owner')
    on conflict (project_id, user_id) do update set role = 'owner';
  elsif not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  else
    update public.projects
    set name = pg_catalog.btrim(p_name),
        updated_at = pg_catalog.transaction_timestamp()
    where project_id = p_project_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'project_id', p_project_id,
    'name', pg_catalog.btrim(p_name)
  );
end;
$$;

revoke all on function public.ensure_project(uuid, text) from public, anon;
grant execute on function public.ensure_project(uuid, text) to authenticated;

commit;
