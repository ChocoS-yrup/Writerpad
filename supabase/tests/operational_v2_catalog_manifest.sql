
begin transaction read only;
with
target_relations(schema_name, relation_name) as (
  values
    ('private','project_purge_tombstones'),
    ('public','projects'),
    ('public','project_members'),
    ('public','documents'),
    ('public','document_versions'),
    ('public','edit_leases'),
    ('public','folders'),
    ('public','folder_versions')
),
target_functions(schema_name, function_name) as (
  values
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
),
manifest as (
  select jsonb_build_object(
    'relations', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'name',c.relname,'kind',c.relkind,
        'rls',c.relrowsecurity,'force_rls',c.relforcerowsecurity
      ) order by n.nspname collate "C",c.relname collate "C")
      from target_relations t
      join pg_namespace n on n.nspname=t.schema_name
      join pg_class c on c.relnamespace=n.oid and c.relname=t.relation_name
    ),'[]'::jsonb),
    'columns', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',x.table_schema,'table',x.table_name,'ordinal',x.ordinal_position,
        'column',x.column_name,'type',x.data_type,'udt',x.udt_name,
        'nullable',x.is_nullable,'default',x.column_default
      ) order by x.table_schema collate "C",x.table_name collate "C",x.ordinal_position)
      from information_schema.columns x
      join target_relations t on t.schema_name=x.table_schema and t.relation_name=x.table_name
    ),'[]'::jsonb),
    'constraints', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'table',c.relname,'name',con.conname,
        'type',con.contype,'definition',pg_get_constraintdef(con.oid,true)
      ) order by n.nspname collate "C",c.relname collate "C",con.conname collate "C")
      from pg_constraint con
      join pg_class c on c.oid=con.conrelid
      join pg_namespace n on n.oid=c.relnamespace
      join target_relations t on t.schema_name=n.nspname and t.relation_name=c.relname
    ),'[]'::jsonb),
    'indexes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',i.schemaname,'table',i.tablename,'name',i.indexname,'definition',i.indexdef
      ) order by i.schemaname collate "C",i.tablename collate "C",i.indexname collate "C")
      from pg_indexes i
      join target_relations t on t.schema_name=i.schemaname and t.relation_name=i.tablename
    ),'[]'::jsonb),
    'policies', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',p.schemaname,'table',p.tablename,'name',p.policyname,
        'permissive',p.permissive,'roles',p.roles,'command',p.cmd,
        'using',p.qual,'check',p.with_check
      ) order by p.schemaname collate "C",p.tablename collate "C",p.policyname collate "C")
      from pg_policies p
      join target_relations t on t.schema_name=p.schemaname and t.relation_name=p.tablename
    ),'[]'::jsonb),
    'functions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'name',p.proname,
        'arguments',pg_get_function_identity_arguments(p.oid),
        'result',pg_get_function_result(p.oid),'language',l.lanname,
        'security_definer',p.prosecdef,'volatility',p.provolatile,
        'body_sha256',encode(extensions.digest(convert_to(
          regexp_replace(btrim(p.prosrc,E' \t\r\n'),E'\r\n?',E'\n','g'),'UTF8'
        ),'sha256'),'hex'),
        'definition_sha256',encode(extensions.digest(convert_to(
          regexp_replace(pg_get_functiondef(p.oid),E'\r\n?',E'\n','g'),'UTF8'
        ),'sha256'),'hex')
      ) order by n.nspname collate "C",p.proname collate "C",
                   pg_get_function_identity_arguments(p.oid) collate "C")
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      join pg_language l on l.oid=p.prolang
      join target_functions t on t.schema_name=n.nspname and t.function_name=p.proname
    ),'[]'::jsonb),
    'table_privileges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',t.schema_name,'table',t.relation_name,'role',r.role_name,
        'select',has_table_privilege(r.role_name,format('%I.%I',t.schema_name,t.relation_name),'SELECT'),
        'insert',has_table_privilege(r.role_name,format('%I.%I',t.schema_name,t.relation_name),'INSERT'),
        'update',has_table_privilege(r.role_name,format('%I.%I',t.schema_name,t.relation_name),'UPDATE'),
        'delete',has_table_privilege(r.role_name,format('%I.%I',t.schema_name,t.relation_name),'DELETE')
      ) order by t.schema_name collate "C",t.relation_name collate "C",
                   r.role_name collate "C")
      from target_relations t
      cross join (values ('anon'),('authenticated'),('service_role')) r(role_name)
    ),'[]'::jsonb),
    'function_privileges', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'name',p.proname,
        'arguments',pg_get_function_identity_arguments(p.oid),'role',r.role_name,
        'execute',has_function_privilege(r.role_name,p.oid,'EXECUTE')
      ) order by n.nspname collate "C",p.proname collate "C",
                   pg_get_function_identity_arguments(p.oid) collate "C",
                   r.role_name collate "C")
      from pg_proc p
      join pg_namespace n on n.oid=p.pronamespace
      join target_functions t on t.schema_name=n.nspname and t.function_name=p.proname
      cross join (values ('anon'),('authenticated'),('service_role')) r(role_name)
    ),'[]'::jsonb),
    'publication', coalesce((
      select jsonb_agg(jsonb_build_object(
        'publication',pubname,'schema',schemaname,'table',tablename
      ) order by pubname collate "C",schemaname collate "C",tablename collate "C")
      from pg_publication_tables
      where pubname='supabase_realtime'
        and (schemaname,tablename) in (('public','documents'),('public','folders'))
    ),'[]'::jsonb),
    'comments', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'object',c.relname,'comment',obj_description(c.oid,'pg_class')
      ) order by n.nspname collate "C",c.relname collate "C")
      from pg_class c
      join pg_namespace n on n.oid=c.relnamespace
      join target_relations t on t.schema_name=n.nspname and t.relation_name=c.relname
      where obj_description(c.oid,'pg_class') is not null
    ),'[]'::jsonb),
    'triggers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',n.nspname,'table',c.relname,'name',g.tgname,
        'definition',pg_get_triggerdef(g.oid,true)
      ) order by n.nspname collate "C",c.relname collate "C",g.tgname collate "C")
      from pg_trigger g
      join pg_class c on c.oid=g.tgrelid
      join pg_namespace n on n.oid=c.relnamespace
      join target_relations t on t.schema_name=n.nspname and t.relation_name=c.relname
      where not g.tgisinternal
    ),'[]'::jsonb),
    'sequences', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schema',sequence_schema,'name',sequence_name,'type',data_type
      ) order by sequence_schema collate "C",sequence_name collate "C")
      from information_schema.sequences
      where sequence_schema in ('public','private')
    ),'[]'::jsonb)
  ) as document
)
select current_setting('transaction_read_only') as transaction_read_only,
       encode(extensions.digest(convert_to(document::text,'UTF8'),'sha256'),'hex') as catalog_snapshot_sha256,
       pg_catalog.octet_length(convert_to(document::text,'UTF8')) as catalog_snapshot_bytes
from manifest;
rollback;
