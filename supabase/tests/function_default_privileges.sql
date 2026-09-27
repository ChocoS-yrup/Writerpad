\set ON_ERROR_STOP on

-- Disposable PostgreSQL CI databases only. Never execute on deployed Supabase.
begin;
set local statement_timeout = '10s';
do $scope$
begin
  if current_database() not in ('writerpad_stage7', 'writerpad_function_defaults_before')
     or current_user <> 'postgres' then
    raise exception 'FUNCTION_DEFAULT_FIXTURE_SCOPE';
  end if;
end;
$scope$;

-- No explicit ACL: assert the effective behavior of newly created functions,
-- rather than merely checking whether a per-schema catalog row is absent.
create function public.default_privilege_probe() returns integer
language sql security definer set search_path = '' as $$ select 7 $$;
create function private.default_privilege_probe() returns integer
language sql security invoker set search_path = '' as $$ select 7 $$;

do $defaults$
declare
  v_role text;
  v_function text;
begin
  foreach v_function in array array[
    'public.default_privilege_probe()', 'private.default_privilege_probe()'
  ] loop
    foreach v_role in array array['anon', 'authenticated', 'service_role'] loop
      if pg_catalog.has_function_privilege(v_role, v_function, 'EXECUTE') then
        raise exception 'NEW_FUNCTION_EXECUTE_EXPOSED: % / %', v_function, v_role;
      end if;
    end loop;
    if not pg_catalog.has_function_privilege('postgres', v_function, 'EXECUTE') then
      raise exception 'FUNCTION_OWNER_EXECUTE_LOST';
    end if;
  end loop;

  begin
    set local role anon;
    perform public.default_privilege_probe();
    reset role;
    raise exception 'ANON_NEW_FUNCTION_CALL_SUCCEEDED';
  exception when insufficient_privilege then
    reset role;
  end;
end;
$defaults$;

-- Explicit application grants still work. Existing RPCs retain their grants.
grant execute on function public.default_privilege_probe() to authenticated;
do $compatibility$
begin
  set local role authenticated;
  if public.default_privilege_probe() <> 7 then
    raise exception 'EXPLICIT_EXECUTE_GRANT_FAILED';
  end if;
  reset role;
  if pg_catalog.has_function_privilege('anon', 'public.default_privilege_probe()', 'EXECUTE')
     or not pg_catalog.has_function_privilege('anon', 'public.document_commit(jsonb)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('anon', 'public.atomic_structure_commit(jsonb)', 'EXECUTE')
     or not pg_catalog.has_function_privilege('authenticated', 'public.validate_project_sync_migration(uuid)', 'EXECUTE')
     or pg_catalog.has_function_privilege('anon', 'public.validate_project_sync_migration(uuid)', 'EXECUTE') then
    raise exception 'EXISTING_RPC_OR_EXPLICIT_GRANT_CHANGED';
  end if;
end;
$compatibility$;

rollback;
\echo 'Function default privilege regression passed'
