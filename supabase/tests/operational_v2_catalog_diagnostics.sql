\set ON_ERROR_STOP on

begin transaction read only;

select
  'FUNCTION' as kind,
  n.nspname || '.' || p.proname || '(' ||
    pg_get_function_identity_arguments(p.oid) || ')' as object,
  md5(regexp_replace(btrim(p.prosrc, E' \t\r\n'), E'\r\n?', E'\n', 'g')) as body_md5,
  p.prosecdef as security_definer,
  p.provolatile as volatility,
  has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
  has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
  has_function_privilege('service_role', p.oid, 'EXECUTE') as service_role_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where (n.nspname, p.proname) in (
  ('private','content_sha256'),
  ('private','has_project_role'),
  ('private','is_valid_entry_name'),
  ('private','is_valid_relative_path'),
  ('public','acquire_edit_lease'),
  ('public','commit_document'),
  ('public','commit_folder'),
  ('public','ensure_project'),
  ('public','get_edit_lease'),
  ('public','get_project_status'),
  ('public','list_trashed_projects'),
  ('public','purge_project'),
  ('public','release_edit_lease'),
  ('public','renew_edit_lease'),
  ('public','restore_project'),
  ('public','touch_editor_locks_locked_at'),
  ('public','touch_writing_contents_updated_at'),
  ('public','trash_project')
)
order by object;

select
  'TABLE_PRIVILEGE' as kind,
  n.nspname || '.' || c.relname as object,
  role_name,
  has_table_privilege(role_name, c.oid, 'SELECT') as can_select,
  has_table_privilege(role_name, c.oid, 'INSERT') as can_insert,
  has_table_privilege(role_name, c.oid, 'UPDATE') as can_update,
  has_table_privilege(role_name, c.oid, 'DELETE') as can_delete
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
cross join (values ('anon'), ('authenticated'), ('service_role')) roles(role_name)
where (n.nspname, c.relname) in (
  ('private','project_purge_tombstones'),
  ('public','projects'),
  ('public','project_members'),
  ('public','documents'),
  ('public','document_versions'),
  ('public','edit_leases'),
  ('public','folders'),
  ('public','folder_versions')
)
order by object, role_name;

select
  'CONSTRAINT' as kind,
  n.nspname || '.' || c.relname || '.' || con.conname as object,
  pg_get_constraintdef(con.oid, true) as definition
from pg_constraint con
join pg_class c on c.oid = con.conrelid
join pg_namespace n on n.oid = c.relnamespace
where (n.nspname, c.relname) in (
  ('private','project_purge_tombstones'),
  ('public','projects'),
  ('public','project_members'),
  ('public','documents'),
  ('public','document_versions'),
  ('public','edit_leases'),
  ('public','folders'),
  ('public','folder_versions')
)
order by object;

select
  'INDEX' as kind,
  schemaname || '.' || tablename || '.' || indexname as object,
  indexdef as definition
from pg_indexes
where (schemaname, tablename) in (
  ('private','project_purge_tombstones'),
  ('public','projects'),
  ('public','project_members'),
  ('public','documents'),
  ('public','document_versions'),
  ('public','edit_leases'),
  ('public','folders'),
  ('public','folder_versions')
)
order by object;

select
  'POLICY' as kind,
  schemaname || '.' || tablename || '.' || policyname as object,
  cmd,
  roles,
  qual,
  with_check
from pg_policies
where (schemaname, tablename) in (
  ('public','projects'),
  ('public','project_members'),
  ('public','documents'),
  ('public','document_versions'),
  ('public','edit_leases'),
  ('public','folders'),
  ('public','folder_versions')
)
order by object;

rollback;
