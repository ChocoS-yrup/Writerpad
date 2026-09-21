begin;

-- Harden legacy helper functions that are not application RPC entry points.
-- The authenticated WriterPad RPCs remain callable as designed, and the two
-- anonymous contract wrappers remain open so unauthenticated requests receive
-- their canonical AUTH_REQUIRED JSON envelopes.

do $baseline$
begin
  if pg_catalog.to_regprocedure('public.touch_editor_locks_locked_at()') is null
     or pg_catalog.to_regprocedure('public.touch_writing_contents_updated_at()') is null then
    raise exception using
      errcode = 'P0001',
      message = 'LEGACY_FUNCTION_HARDENING_BASELINE_MISSING';
  end if;
end;
$baseline$;

-- Event triggers invoke their registered function through the trigger manager;
-- it is not an application RPC and needs no direct Data API execution grant.
do $harden_rls_event_trigger$
declare
  v_function regprocedure := pg_catalog.to_regprocedure('public.rls_auto_enable()');
begin
  -- This platform helper is present in deployed Supabase projects but absent
  -- from the repository's blank-PostgreSQL bootstrap chain.
  if v_function is null then
    return;
  end if;
  if not exists (
    select 1
    from pg_catalog.pg_event_trigger
    where evtname = 'ensure_rls'
      and evtevent = 'ddl_command_end'
      and evtfoid = v_function::oid
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'RLS_AUTO_ENABLE_EVENT_TRIGGER_MISMATCH';
  end if;
  execute 'revoke all on function public.rls_auto_enable() from public, anon, authenticated, service_role';
end;
$harden_rls_event_trigger$;

-- These legacy trigger functions currently have no attached row triggers.
-- Keep them for catalog compatibility, but make name resolution deterministic
-- and remove direct application-role execution.
alter function public.touch_editor_locks_locked_at()
  security invoker
  set search_path = '';
alter function public.touch_writing_contents_updated_at()
  security invoker
  set search_path = '';

revoke all on function public.touch_editor_locks_locked_at()
  from public, anon, authenticated, service_role;
revoke all on function public.touch_writing_contents_updated_at()
  from public, anon, authenticated, service_role;

-- New public-schema functions must be explicitly granted to an API role.
alter default privileges for role postgres in schema public
  revoke execute on functions from public;

do $verify$
begin
  if pg_catalog.has_function_privilege('anon', 'public.touch_editor_locks_locked_at()', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'public.touch_editor_locks_locked_at()', 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', 'public.touch_editor_locks_locked_at()', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'public.touch_writing_contents_updated_at()', 'EXECUTE')
     or pg_catalog.has_function_privilege('authenticated', 'public.touch_writing_contents_updated_at()', 'EXECUTE')
     or pg_catalog.has_function_privilege('service_role', 'public.touch_writing_contents_updated_at()', 'EXECUTE') then
    raise exception using
      errcode = 'P0001',
      message = 'LEGACY_FUNCTION_HARDENING_PRIVILEGE_MISMATCH';
  end if;
  if pg_catalog.to_regprocedure('public.rls_auto_enable()') is not null
     and (
       pg_catalog.has_function_privilege('anon', 'public.rls_auto_enable()', 'EXECUTE')
       or pg_catalog.has_function_privilege('authenticated', 'public.rls_auto_enable()', 'EXECUTE')
       or pg_catalog.has_function_privilege('service_role', 'public.rls_auto_enable()', 'EXECUTE')
     ) then
    raise exception using
      errcode = 'P0001',
      message = 'RLS_AUTO_ENABLE_PRIVILEGE_MISMATCH';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_proc
    where oid in (
      'public.touch_editor_locks_locked_at()'::regprocedure,
      'public.touch_writing_contents_updated_at()'::regprocedure
    )
      and (
        prosecdef
        or not ('search_path=""' = any(
          coalesce(proconfig, array[]::text[])
        ))
      )
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'LEGACY_FUNCTION_HARDENING_CONFIG_MISMATCH';
  end if;
  if exists (
    select 1
    from pg_catalog.pg_default_acl default_acl
    cross join lateral pg_catalog.aclexplode(default_acl.defaclacl) privilege
    where default_acl.defaclrole = 'postgres'::regrole
      and default_acl.defaclnamespace = 'public'::regnamespace
      and default_acl.defaclobjtype = 'f'
      and privilege.grantee = 0
      and privilege.privilege_type = 'EXECUTE'
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'PUBLIC_FUNCTION_DEFAULT_PRIVILEGE_MISMATCH';
  end if;
end;
$verify$;

commit;
