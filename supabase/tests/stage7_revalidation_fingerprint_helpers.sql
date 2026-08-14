-- Session-local fingerprint helpers for the Stage 7 staging revalidation.
-- No persistent schema object is created by this file.

set plpgsql.variable_conflict = error;

create or replace function pg_temp.writerpad_query_fingerprint(p_query text)
returns text
language plpgsql
as $function$
#variable_conflict error
declare
  v_fingerprint text;
begin
  execute pg_catalog.format(
    $sql$
      select pg_catalog.md5(
        pg_catalog.coalesce(
          pg_catalog.string_agg(v_row_json, E'\n' order by v_row_json),
          ''
        )
      )
      from (
        select pg_catalog.to_jsonb(v_row)::text as v_row_json
        from (%s) as v_row
      ) as v_rows
    $sql$,
    p_query
  )
  into v_fingerprint;

  return v_fingerprint;
end
$function$;

create or replace function pg_temp.writerpad_project_snapshot(p_project_id uuid)
returns text
language plpgsql
as $function$
#variable_conflict error
begin
  return pg_catalog.md5(pg_catalog.concat_ws(
    '|',
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select p.* from public.projects as p where p.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select pm.* from public.project_members as pm where pm.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select f.* from public.folders as f where f.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select fv.* from public.folder_versions as fv join public.folders as f on f.folder_id = fv.folder_id where f.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select d.* from public.documents as d where d.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select dv.* from public.document_versions as dv join public.documents as d on d.document_id = dv.document_id where d.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select el.* from public.edit_leases as el join public.documents as d on d.document_id = el.document_id where d.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select t.* from public.tree_orders as t where t.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select b.* from public.sync_batches as b where b.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select br.* from public.sync_batch_results as br join public.sync_batches as b on b.batch_id = br.batch_id where b.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select o.* from public.sync_operations as o where o.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select a.* from public.sync_operation_attempts as a join public.sync_operations as o on o.operation_id = a.operation_id where o.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select e.* from public.sync_operation_events as e join public.sync_operations as o on o.operation_id = e.operation_id where o.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select s.* from public.project_sync_settings as s where s.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select m.* from public.project_sync_migrations as m where m.project_id = %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select pt.* from private.project_purge_tombstones as pt where pt.project_id = %L::uuid',
      p_project_id
    ))
  ));
end
$function$;

create or replace function pg_temp.writerpad_state_without_project(p_project_id uuid)
returns text
language plpgsql
as $function$
#variable_conflict error
begin
  return pg_catalog.md5(pg_catalog.concat_ws(
    '|',
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select p.* from public.projects as p where p.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select pm.* from public.project_members as pm where pm.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select f.* from public.folders as f where f.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select fv.* from public.folder_versions as fv join public.folders as f on f.folder_id = fv.folder_id where f.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select d.* from public.documents as d where d.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select dv.* from public.document_versions as dv join public.documents as d on d.document_id = dv.document_id where d.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select el.* from public.edit_leases as el join public.documents as d on d.document_id = el.document_id where d.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select t.* from public.tree_orders as t where t.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select b.* from public.sync_batches as b where b.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select br.* from public.sync_batch_results as br join public.sync_batches as b on b.batch_id = br.batch_id where b.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select o.* from public.sync_operations as o where o.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select a.* from public.sync_operation_attempts as a join public.sync_operations as o on o.operation_id = a.operation_id where o.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select e.* from public.sync_operation_events as e join public.sync_operations as o on o.operation_id = e.operation_id where o.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select s.* from public.project_sync_settings as s where s.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select m.* from public.project_sync_migrations as m where m.project_id <> %L::uuid',
      p_project_id
    )),
    pg_temp.writerpad_query_fingerprint(pg_catalog.format(
      'select pt.* from private.project_purge_tombstones as pt where pt.project_id <> %L::uuid',
      p_project_id
    ))
  ));
end
$function$;
