\set ON_ERROR_STOP on

begin transaction read only;

select
  pg_catalog.current_database() as database_name,
  pg_catalog.current_setting('server_version') as server_version,
  pg_catalog.current_setting('server_encoding') as server_encoding,
  pg_catalog.current_setting('lc_collate') as lc_collate,
  pg_catalog.current_setting('TimeZone') as timezone;

select
  to_regclass('supabase_migrations.schema_migrations') as migration_ledger,
  to_regclass('public.projects') as projects,
  to_regclass('public.documents') as documents,
  to_regclass('public.document_versions') as document_versions,
  to_regclass('public.folders') as folders,
  to_regclass('public.sync_batches') as sync_batches,
  to_regclass('public.sync_operations') as sync_operations,
  to_regclass('public.project_sync_settings') as project_sync_settings;

select
  n.nspname as schema_name,
  c.relname as relation_name,
  c.relkind,
  pg_catalog.obj_description(c.oid, 'pg_class') as description
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public', 'private', 'supabase_migrations')
  and c.relname in (
    'schema_migrations', 'projects', 'project_members', 'documents',
    'document_versions', 'folders', 'folder_versions', 'tree_orders',
    'sync_contract_allowlist', 'sync_batches', 'sync_operations',
    'sync_operation_attempts', 'sync_operation_events',
    'project_sync_settings', 'project_sync_migrations'
  )
order by n.nspname, c.relname;

select
  n.nspname as schema_name,
  p.proname,
  pg_catalog.pg_get_function_identity_arguments(p.oid) as identity_arguments,
  p.prosecdef as security_definer,
  p.provolatile as volatility
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private')
  and p.proname in (
    'ensure_project', 'commit_document', 'commit_document_contract',
    'commit_folder', 'atomic_structure_commit',
    'cancel_sync_operation', 'begin_project_sync_migration',
    'validate_project_sync_migration', 'complete_project_sync_migration',
    'storage_name_v1'
  )
order by n.nspname, p.proname, identity_arguments;

select
  table_schema,
  table_name,
  column_name,
  data_type,
  is_nullable,
  column_default
from information_schema.columns
where table_schema in ('public', 'private')
  and table_name in (
    'projects', 'documents', 'document_versions', 'folders', 'tree_orders',
    'sync_contract_allowlist', 'sync_batches', 'sync_operations',
    'sync_operation_attempts', 'sync_operation_events',
    'project_sync_settings', 'project_sync_migrations'
  )
order by table_schema, table_name, ordinal_position;

-- Catalog-only collision and provenance risk indicators. These do not mutate
-- data and remain useful even before the Stage 7 tables exist.
select
  conrelid::regclass::text as relation_name,
  conname,
  pg_catalog.pg_get_constraintdef(oid, true) as definition
from pg_catalog.pg_constraint
where conrelid in (
  select relation::oid
  from pg_catalog.unnest(array[
    to_regclass('public.documents'),
    to_regclass('public.folders'),
    to_regclass('public.sync_operations')
  ]) relation
  where relation is not null
)
order by relation_name, conname;

do $preflight$
declare
  v_sql text;
  v_row record;
begin
  if to_regclass('supabase_migrations.schema_migrations') is not null then
    raise notice 'SUPABASE MIGRATION LEDGER (latest first)';
    for v_row in execute
      'select version from supabase_migrations.schema_migrations order by version desc limit 50'
    loop
      raise notice 'migration=%', v_row.version;
    end loop;
  else
    raise notice 'supabase_migrations.schema_migrations is not visible';
  end if;

  if to_regclass('public.projects') is not null then
    execute 'select count(*) from public.projects' into v_row;
    raise notice 'projects=%', v_row.count;
  end if;

  if to_regclass('public.document_versions') is not null then
    execute 'select count(*) from public.document_versions' into v_row;
    raise notice 'document_versions=%', v_row.count;
  end if;

  if to_regclass('public.folder_versions') is not null then
    execute 'select count(*) from public.folder_versions' into v_row;
    raise notice 'folder_versions=%', v_row.count;
  end if;

  if to_regclass('public.document_versions') is not null
     and to_regclass('public.folder_versions') is not null then
    v_sql := $audit$
      select count(*)
      from public.document_versions d
      join public.folder_versions f using (operation_id)
    $audit$;
    execute v_sql into v_row;
    raise notice 'cross-ledger operation_id collisions=%', v_row.count;
  end if;
end;
$preflight$;

rollback;
