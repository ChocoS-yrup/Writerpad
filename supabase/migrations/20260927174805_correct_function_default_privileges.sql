begin;

-- Per-schema REVOKE cannot subtract PostgreSQL's global PUBLIC EXECUTE
-- default. Correct the earlier schema-only hardening without changing it.
-- This affects FUTURE functions created by postgres across all schemas
-- (unless explicitly granted per schema); existing RPC ACLs are untouched.
alter default privileges for role postgres
  revoke execute on functions from public;
alter default privileges for role postgres in schema public
  revoke execute on functions from public;

do $verify$
begin
  -- A missing global pg_default_acl row means the built-in defaults apply;
  -- it is not evidence that PUBLIC execution has been revoked.
  if exists (
    select 1
    from pg_catalog.aclexplode(coalesce(
      (select defaclacl from pg_catalog.pg_default_acl
       where defaclrole = 'postgres'::regrole
         and defaclnamespace = 0 and defaclobjtype = 'f'),
      pg_catalog.acldefault('f', 'postgres'::regrole)
    )) privilege
    where privilege.grantee = 0 and privilege.privilege_type = 'EXECUTE'
  ) or exists (
    select 1
    from pg_catalog.pg_default_acl defaults
    cross join lateral pg_catalog.aclexplode(defaults.defaclacl) privilege
    where defaults.defaclrole = 'postgres'::regrole
      and defaults.defaclnamespace = 'public'::regnamespace
      and defaults.defaclobjtype = 'f'
      and privilege.grantee = 0 and privilege.privilege_type = 'EXECUTE'
  ) then
    raise exception using errcode = 'P0001',
      message = 'FUNCTION_DEFAULT_PUBLIC_EXECUTE_NOT_REVOKED';
  end if;
end;
$verify$;

commit;
