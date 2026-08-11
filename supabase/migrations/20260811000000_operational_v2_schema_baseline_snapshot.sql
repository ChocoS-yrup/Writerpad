-- purpose: bootstrap blank staging/new environment
-- historical_migration_replay: false
-- production_execution: forbidden
-- production_reconciliation_required: true
-- source_catalog_project: redacted
-- source_catalog_snapshot_sha256: 6c71ff36a90993dc327557b4a1a64c0dfb27b347134ed89e7f126dae76c6ff9a
--
-- This is a schema-only squashed snapshot of the current operational v2
-- catalog. It contains no application rows, document bodies or paths, auth
-- metadata, secrets, sequence values, endpoint, URL, or project identifier.
-- Existing environments must use a separately approved exact-catalog ledger
-- reconciliation; never execute this snapshot against them.

begin;

do $empty_app_schema$
begin
  if to_regclass('public.projects') is not null
     or to_regclass('public.project_members') is not null
     or to_regclass('public.documents') is not null
     or to_regclass('public.document_versions') is not null
     or to_regclass('public.edit_leases') is not null
     or to_regclass('public.folders') is not null
     or to_regclass('public.folder_versions') is not null
     or to_regclass('private.project_purge_tombstones') is not null then
    raise exception using
      errcode = 'P0001',
      message = 'BASELINE_SNAPSHOT_REQUIRES_EMPTY_APP_SCHEMA',
      detail = 'This current-schema snapshot is only for a blank app schema; use approved ledger reconciliation for an existing environment.';
  end if;
end;
$empty_app_schema$;

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists private;

revoke all on schema private from public, anon, authenticated;

create or replace function private.is_valid_relative_path(p_path text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select
    p_path is not null
    and p_path <> ''
    and p_path = pg_catalog.btrim(p_path)
    and pg_catalog.length(p_path) <= 1024
    and p_path !~ E'(^/|\\\\|//|(^|/)\\.{1,2}(/|$)|/$)';
$$;

create or replace function private.content_sha256(p_content text)
returns text
language sql
immutable
strict
set search_path = ''
as $$
  select pg_catalog.encode(
    extensions.digest(pg_catalog.convert_to(p_content, 'UTF8'), 'sha256'),
    'hex'
  );
$$;

create table public.projects (
  project_id uuid primary key,
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null check (pg_catalog.btrim(name) <> ''),
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  trashed_at timestamptz,
  trashed_by uuid references auth.users(id) on delete restrict,
  constraint projects_trash_state_ck check (
    (trashed_at is null and trashed_by is null)
    or (trashed_at is not null and trashed_by is not null)
  )
);

create index projects_owner_trash_idx
  on public.projects(owner_id, trashed_at, project_id);

create table public.project_members (
  project_id uuid not null references public.projects(project_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner', 'editor', 'viewer')),
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  primary key (project_id, user_id)
);

create index project_members_user_project_idx
  on public.project_members(user_id, project_id);

create table public.documents (
  document_id uuid primary key,
  project_id uuid not null references public.projects(project_id) on delete cascade,
  relative_path text not null check (private.is_valid_relative_path(relative_path)),
  content text not null check (pg_catalog.octet_length(content) <= 10485760),
  revision bigint not null check (revision >= 1),
  current_version_id uuid,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint documents_deleted_at_ck check (
    (is_deleted and deleted_at is not null)
    or (not is_deleted and deleted_at is null)
  ),
  unique (document_id, project_id)
);

create unique index documents_live_path_uidx
  on public.documents(project_id, relative_path)
  where not is_deleted;

create index documents_project_revision_idx
  on public.documents(project_id, revision);

create index documents_project_updated_idx
  on public.documents(project_id, updated_at, document_id);

create table public.document_versions (
  version_id uuid primary key default pg_catalog.gen_random_uuid(),
  document_id uuid not null,
  project_id uuid not null,
  revision bigint not null check (revision >= 1),
  base_revision bigint not null check (base_revision >= 0),
  operation_id uuid not null,
  device_id uuid not null,
  operation_kind text not null check (
    operation_kind in ('create', 'update', 'move', 'delete', 'restore')
  ),
  relative_path text not null check (private.is_valid_relative_path(relative_path)),
  content text not null check (pg_catalog.octet_length(content) <= 10485760),
  content_hash text not null check (content_hash ~ '^[0-9a-f]{64}$'),
  is_deleted boolean not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint document_versions_document_fk
    foreign key (document_id, project_id)
    references public.documents(document_id, project_id)
    on delete cascade,
  unique (document_id, revision),
  unique (operation_id),
  unique (document_id, version_id)
);

alter table public.documents
  add constraint documents_current_version_fk
  foreign key (document_id, current_version_id)
  references public.document_versions(document_id, version_id)
  deferrable initially deferred;

create index document_versions_project_created_idx
  on public.document_versions(project_id, created_at, document_id);

create table public.edit_leases (
  document_id uuid primary key references public.documents(document_id) on delete cascade,
  lease_token uuid not null unique default pg_catalog.gen_random_uuid(),
  holder_user_id uuid not null references auth.users(id) on delete cascade,
  holder_device_id uuid not null,
  acquired_at timestamptz not null default pg_catalog.transaction_timestamp(),
  renewed_at timestamptz not null default pg_catalog.transaction_timestamp(),
  expires_at timestamptz not null,
  check (expires_at > renewed_at)
);

create index edit_leases_expiry_idx on public.edit_leases(expires_at);

CREATE OR REPLACE FUNCTION private.has_project_role(p_project_id uuid, p_user_id uuid, p_minimum_role text DEFAULT 'viewer'::text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select
    p_user_id is not null
    and p_minimum_role in ('owner', 'editor', 'viewer')
    and exists (
      select 1
      from public.projects p
      left join public.project_members m
        on m.project_id = p.project_id
       and m.user_id = p_user_id
      where p.project_id = p_project_id
        and p.trashed_at is null
        and (
          p.owner_id = p_user_id
          or case p_minimum_role
            when 'owner' then m.role = 'owner'
            when 'editor' then m.role in ('owner', 'editor')
            when 'viewer' then m.role in ('owner', 'editor', 'viewer')
          end
        )
    );
$function$;

revoke all on function private.has_project_role(uuid, uuid, text) from public;
revoke all on function private.is_valid_relative_path(text) from public;
revoke all on function private.content_sha256(text) from public;
grant usage on schema private to authenticated;
grant execute on function private.has_project_role(uuid, uuid, text) to authenticated;

alter table public.projects enable row level security;
alter table public.projects force row level security;
alter table public.project_members enable row level security;
alter table public.project_members force row level security;
alter table public.documents enable row level security;
alter table public.documents force row level security;
alter table public.document_versions enable row level security;
alter table public.document_versions force row level security;
alter table public.edit_leases enable row level security;
alter table public.edit_leases force row level security;

create policy projects_read_members
on public.projects
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

create policy project_members_read_members
on public.project_members
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

create policy documents_read_members
on public.documents
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

create policy document_versions_read_members
on public.document_versions
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

-- edit_leases intentionally has no direct SELECT policy: lease_token must remain secret.

revoke all on table public.projects from anon, authenticated;
revoke all on table public.project_members from anon, authenticated;
revoke all on table public.documents from anon, authenticated;
revoke all on table public.document_versions from anon, authenticated;
revoke all on table public.edit_leases from anon, authenticated;

grant select on table public.projects to authenticated;
grant select on table public.project_members to authenticated;
grant select on table public.documents to authenticated;
grant select on table public.document_versions to authenticated;

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
  elsif v_owner_id = v_user_id then
    insert into public.project_members (project_id, user_id, role)
    values (p_project_id, v_user_id, 'owner')
    on conflict (project_id, user_id) do update set role = 'owner';
    update public.projects
    set name = pg_catalog.btrim(p_name),
        updated_at = pg_catalog.transaction_timestamp()
    where project_id = p_project_id;
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

create or replace function public.acquire_edit_lease(
  p_document_id uuid,
  p_device_id uuid,
  p_ttl_seconds integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_ttl integer;
  v_document public.documents%rowtype;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  v_ttl := greatest(30, least(coalesce(p_ttl_seconds, 90), 120));

  select * into v_document
  from public.documents
  where document_id = p_document_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_document.project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  delete from public.edit_leases
  where document_id = p_document_id and expires_at <= v_now;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
  for update;

  if found then
    if v_lease.holder_user_id <> v_user_id
       or v_lease.holder_device_id <> p_device_id then
      raise exception using
        errcode = 'P0001',
        message = 'LEASE_CONFLICT',
        detail = pg_catalog.jsonb_build_object('expires_at', v_lease.expires_at)::text;
    end if;

    update public.edit_leases
    set renewed_at = v_now,
        expires_at = v_now + pg_catalog.make_interval(secs => v_ttl)
    where document_id = p_document_id
    returning * into v_lease;
  else
    insert into public.edit_leases (
      document_id, holder_user_id, holder_device_id, expires_at
    ) values (
      p_document_id, v_user_id, p_device_id,
      v_now + pg_catalog.make_interval(secs => v_ttl)
    )
    returning * into v_lease;
  end if;

  return pg_catalog.jsonb_build_object(
    'document_id', v_lease.document_id,
    'lease_token', v_lease.lease_token,
    'device_id', v_lease.holder_device_id,
    'expires_at', v_lease.expires_at
  );
end;
$$;

create or replace function public.renew_edit_lease(
  p_document_id uuid,
  p_device_id uuid,
  p_lease_token uuid,
  p_ttl_seconds integer default 90
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();

  v_ttl integer;
  v_project_id uuid;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null or p_lease_token is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select project_id into v_project_id
  from public.documents
  where document_id = p_document_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
  for update;

  if not found
     or v_lease.holder_user_id <> v_user_id
     or v_lease.holder_device_id <> p_device_id
     or v_lease.lease_token <> p_lease_token
     or v_lease.expires_at <= v_now then
    delete from public.edit_leases
    where document_id = p_document_id and expires_at <= v_now;
    raise exception using errcode = 'P0001', message = 'LEASE_EXPIRED';
  end if;

  v_ttl := greatest(30, least(coalesce(p_ttl_seconds, 90), 120));
  update public.edit_leases
  set renewed_at = v_now,
      expires_at = v_now + pg_catalog.make_interval(secs => v_ttl)
  where document_id = p_document_id
  returning * into v_lease;

  return pg_catalog.jsonb_build_object(
    'document_id', v_lease.document_id,
    'lease_token', v_lease.lease_token,
    'device_id', v_lease.holder_device_id,
    'expires_at', v_lease.expires_at
  );
end;
$$;

create or replace function public.release_edit_lease(
  p_document_id uuid,
  p_device_id uuid,
  p_lease_token uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null or p_lease_token is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  delete from public.edit_leases
  where document_id = p_document_id
    and holder_user_id = v_user_id
    and holder_device_id = p_device_id
    and lease_token = p_lease_token;

  return found;
end;
$$;

create or replace function public.get_edit_lease(
  p_document_id uuid,
  p_device_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_project_id uuid;
  v_lease public.edit_leases%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null or p_device_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select project_id into v_project_id
  from public.documents
  where document_id = p_document_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
  end if;
  if not private.has_project_role(v_project_id, v_user_id, 'viewer') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_lease
  from public.edit_leases
  where document_id = p_document_id
    and expires_at > pg_catalog.transaction_timestamp();

  if not found then
    return pg_catalog.jsonb_build_object(
      'document_id', p_document_id,
      'state', 'available'
    );
  end if;

  return pg_catalog.jsonb_build_object(
    'document_id', p_document_id,
    'state', case
      when v_lease.holder_user_id = v_user_id
       and v_lease.holder_device_id = p_device_id then 'held_by_me'
      else 'held_by_other'
    end,
    'expires_at', v_lease.expires_at
  );
end;
$$;

create or replace function public.commit_document(
  p_document_id uuid,
  p_project_id uuid,
  p_base_revision bigint,
  p_operation_id uuid,
  p_device_id uuid,
  p_relative_path text,
  p_content text,
  p_is_deleted boolean default false,
  p_lease_token uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_hash text;
  v_document public.documents%rowtype;
  v_version public.document_versions%rowtype;
  v_lease public.edit_leases%rowtype;
  v_revision bigint;
  v_kind text;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_document_id is null
     or p_project_id is null
     or p_operation_id is null
     or p_device_id is null
     or p_base_revision is null
     or p_base_revision < 0
     or p_is_deleted is null
     or p_relative_path is null
     or p_content is null
     or not private.is_valid_relative_path(p_relative_path)
     or pg_catalog.octet_length(p_content) > 10485760 then

    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  v_hash := private.content_sha256(p_content);

  -- A fixed lock order makes operation replay, document creation and path checks deterministic.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('operation:' || p_operation_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('document:' || p_document_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select dv.* into v_version
  from public.document_versions dv
  where dv.operation_id = p_operation_id;

  if found then
    if v_version.document_id <> p_document_id
       or v_version.project_id <> p_project_id
       or v_version.base_revision <> p_base_revision
       or v_version.device_id <> p_device_id
       or v_version.relative_path <> p_relative_path
       or v_version.content_hash <> v_hash
       or v_version.is_deleted <> p_is_deleted
       or v_version.created_by <> v_user_id then
      raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
    end if;

    return pg_catalog.jsonb_build_object(
      'status', 'replayed',
      'document_id', v_version.document_id,
      'version_id', v_version.version_id,
      'operation_id', v_version.operation_id,
      'operation_kind', v_version.operation_kind,
      'revision', v_version.revision,
      'relative_path', v_version.relative_path,
      'is_deleted', v_version.is_deleted,
      'content_hash', v_version.content_hash,
      'committed_at', v_version.created_at
    );
  end if;

  select * into v_document
  from public.documents
  where document_id = p_document_id
  for update;

  if p_base_revision = 0 then
    if found then
      raise exception using errcode = 'P0001', message = 'DOCUMENT_ALREADY_EXISTS';
    end if;
    if p_is_deleted or p_lease_token is not null then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if exists (
      select 1 from public.documents
      where project_id = p_project_id
        and relative_path = p_relative_path
        and not is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
    end if;

    v_revision := 1;
    v_kind := 'create';
    insert into public.documents (
      document_id, project_id, relative_path, content, revision,
      is_deleted, deleted_at, created_by, updated_by, created_at, updated_at
    ) values (
      p_document_id, p_project_id, p_relative_path, p_content, v_revision,
      false, null, v_user_id, v_user_id, v_now, v_now
    );
  else
    if not found or v_document.project_id <> p_project_id then
      raise exception using errcode = 'P0001', message = 'DOCUMENT_NOT_FOUND';
    end if;
    if v_document.revision <> p_base_revision then
      raise exception using
        errcode = 'P0001',
        message = 'REVISION_CONFLICT',
        detail = pg_catalog.jsonb_build_object(
          'current_revision', v_document.revision,
          'current_hash', private.content_sha256(v_document.content),
          'is_deleted', v_document.is_deleted
        )::text;
    end if;
    if p_lease_token is null then
      raise exception using errcode = 'P0001', message = 'LEASE_REQUIRED';
    end if;

    select * into v_lease
    from public.edit_leases
    where document_id = p_document_id
    for update;

    if not found
       or v_lease.holder_user_id <> v_user_id
       or v_lease.holder_device_id <> p_device_id
       or v_lease.lease_token <> p_lease_token
       or v_lease.expires_at <= v_now then
      delete from public.edit_leases
      where document_id = p_document_id and expires_at <= v_now;
      raise exception using errcode = 'P0001', message = 'LEASE_EXPIRED';
    end if;

    if not p_is_deleted and exists (
      select 1 from public.documents
      where project_id = p_project_id
        and relative_path = p_relative_path
        and document_id <> p_document_id
        and not is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'PATH_CONFLICT';
    end if;

    v_revision := v_document.revision + 1;
    v_kind := case
      when not v_document.is_deleted and p_is_deleted then 'delete'
      when v_document.is_deleted and not p_is_deleted then 'restore'
      when v_document.relative_path <> p_relative_path
       and v_document.content = p_content then 'move'
      else 'update'
    end;
  end if;

  insert into public.document_versions (
    document_id, project_id, revision, base_revision, operation_id, device_id,
    operation_kind, relative_path, content, content_hash, is_deleted,
    created_by, created_at
  ) values (
    p_document_id, p_project_id, v_revision, p_base_revision, p_operation_id, p_device_id,
    v_kind, p_relative_path, p_content, v_hash, p_is_deleted,
    v_user_id, v_now
  )
  returning * into v_version;

  update public.documents
  set relative_path = p_relative_path,
      content = p_content,
      revision = v_revision,
      current_version_id = v_version.version_id,
      is_deleted = p_is_deleted,
      deleted_at = case when p_is_deleted then v_now else null end,
      updated_by = v_user_id,
      updated_at = v_now
  where document_id = p_document_id;

  if p_is_deleted then
    delete from public.edit_leases where document_id = p_document_id;
  elsif p_base_revision > 0 then
    update public.edit_leases
    set renewed_at = v_now,
        expires_at = v_now + pg_catalog.make_interval(secs => 90)
    where document_id = p_document_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'committed',
    'document_id', v_version.document_id,
    'version_id', v_version.version_id,
    'operation_id', v_version.operation_id,
    'operation_kind', v_version.operation_kind,
    'revision', v_version.revision,
    'relative_path', v_version.relative_path,
    'is_deleted', v_version.is_deleted,
    'content_hash', v_version.content_hash,
    'committed_at', v_version.created_at
  );
end;
$$;

revoke all on function public.acquire_edit_lease(uuid, uuid, integer) from public, anon;
revoke all on function public.ensure_project(uuid, text) from public, anon;

revoke all on function public.renew_edit_lease(uuid, uuid, uuid, integer) from public, anon;
revoke all on function public.release_edit_lease(uuid, uuid, uuid) from public, anon;
revoke all on function public.get_edit_lease(uuid, uuid) from public, anon;
revoke all on function public.commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid) from public, anon;

grant execute on function public.acquire_edit_lease(uuid, uuid, integer) to authenticated;
grant execute on function public.ensure_project(uuid, text) to authenticated;
grant execute on function public.renew_edit_lease(uuid, uuid, uuid, integer) to authenticated;
grant execute on function public.release_edit_lease(uuid, uuid, uuid) to authenticated;
grant execute on function public.get_edit_lease(uuid, uuid) to authenticated;
grant execute on function public.commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid) to authenticated;

-- Realtime is only a wake-up signal; clients must reconcile by revision after reconnect.
do $$
begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
       from pg_catalog.pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'documents'
     ) then
    alter publication supabase_realtime add table public.documents;
  end if;
end;
$$;

comment on table public.documents is
  'Supabase sync v2 current document projection. All writes go through commit_document.';
comment on table public.document_versions is
  'Supabase sync v2 immutable full-snapshot commit ledger.';
comment on table public.edit_leases is
  'Short-lived edit leases. Tokens are never directly selectable by app roles.';
comment on function public.commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid) is
  'Atomic, optimistic and idempotent document commit RPC for sync protocol v2.';

CREATE OR REPLACE FUNCTION private.is_valid_entry_name(p_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO ''
AS $function$
  select
    p_name is not null
    and p_name <> ''
    and p_name = pg_catalog.btrim(p_name)
    and pg_catalog.char_length(p_name) <= 255
    and p_name not in ('.', '..')
    and pg_catalog.right(p_name, 1) <> '.'
    and p_name !~ E'[<>:"/\\\\|?*]'
    and p_name !~ '[[:cntrl:]]'
    and pg_catalog.upper(pg_catalog.split_part(p_name, '.', 1)) <> all (
      array[
        'CON', 'PRN', 'AUX', 'NUL', 'CLOCK$',
        'COM1', 'COM2', 'COM3', 'COM4', 'COM5',
        'COM6', 'COM7', 'COM8', 'COM9',
        'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5',
        'LPT6', 'LPT7', 'LPT8', 'LPT9'
      ]::text[]
    );
$function$;

create table private.project_purge_tombstones (
  project_id uuid primary key,
  owner_id uuid not null,
  purged_by uuid not null,
  purged_at timestamptz not null default pg_catalog.transaction_timestamp()
);

create table public.folders (
  folder_id uuid primary key,
  project_id uuid not null references public.projects(project_id) on delete cascade,
  parent_folder_id uuid,
  name text not null check (private.is_valid_entry_name(name)),
  revision bigint not null check (revision >= 1),
  current_version_id uuid,
  is_deleted boolean not null default false,
  deleted_at timestamptz,
  created_by uuid not null references auth.users(id) on delete restrict,
  updated_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  updated_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint folders_deleted_at_ck check (
    (is_deleted and deleted_at is not null)
    or (not is_deleted and deleted_at is null)
  ),
  constraint folders_not_own_parent_ck check (
    parent_folder_id is distinct from folder_id
  ),
  constraint folders_identity_project_uk unique (folder_id, project_id),
  constraint folders_parent_fk
    foreign key (parent_folder_id, project_id)
    references public.folders(folder_id, project_id)
    deferrable initially deferred
);

create unique index folders_live_child_name_uidx
  on public.folders(project_id, parent_folder_id, pg_catalog.lower(name))
  where parent_folder_id is not null and not is_deleted;

create unique index folders_live_root_name_uidx
  on public.folders(project_id, pg_catalog.lower(name))
  where parent_folder_id is null and not is_deleted;

create index folders_project_parent_idx
  on public.folders(project_id, parent_folder_id, folder_id);

create index folders_project_revision_idx
  on public.folders(project_id, revision, folder_id);

create table public.folder_versions (
  version_id uuid primary key default pg_catalog.gen_random_uuid(),
  folder_id uuid not null,
  project_id uuid not null,
  revision bigint not null check (revision >= 1),
  base_revision bigint not null check (base_revision >= 0),
  operation_id uuid not null unique,
  device_id uuid not null,
  operation_kind text not null check (
    operation_kind in ('create', 'rename', 'move', 'update', 'delete', 'restore')
  ),
  parent_folder_id uuid,
  name text not null check (private.is_valid_entry_name(name)),
  is_deleted boolean not null,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default pg_catalog.transaction_timestamp(),
  constraint folder_versions_folder_fk
    foreign key (folder_id, project_id)
    references public.folders(folder_id, project_id)
    on delete cascade,
  unique (folder_id, revision),
  unique (folder_id, version_id)
);

alter table public.folders
  add constraint folders_current_version_fk
  foreign key (folder_id, current_version_id)
  references public.folder_versions(folder_id, version_id)
  deferrable initially deferred;

create index folder_versions_project_created_idx
  on public.folder_versions(project_id, created_at, folder_id);

CREATE OR REPLACE FUNCTION public.commit_folder(p_folder_id uuid, p_project_id uuid, p_base_revision bigint, p_operation_id uuid, p_device_id uuid, p_parent_folder_id uuid, p_name text, p_is_deleted boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_folder public.folders%rowtype;
  v_parent public.folders%rowtype;
  v_version public.folder_versions%rowtype;
  v_revision bigint;
  v_kind text;
  v_cycle boolean := false;
  v_folder_exists boolean := false;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_folder_id is null
     or p_project_id is null
     or p_operation_id is null
     or p_device_id is null
     or p_base_revision is null
     or p_base_revision < 0
     or p_is_deleted is null
     or not private.is_valid_entry_name(p_name) then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;
  if p_parent_folder_id = p_folder_id then
    raise exception using errcode = 'P0001', message = 'FOLDER_CYCLE';
  end if;

  -- One project lock serializes sibling-name and ancestry checks. The operation
  -- and folder locks make a retry with the same UUID deterministic.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('operation:' || p_operation_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('folder:' || p_folder_id::text, 0)
  );
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1
      from private.project_purge_tombstones tombstone
      where tombstone.project_id = p_project_id
        and tombstone.owner_id = v_user_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.trashed_at is not null then
    raise exception using errcode = 'P0001', message = 'PROJECT_TRASHED';
  end if;
  if not private.has_project_role(p_project_id, v_user_id, 'editor') then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  select * into v_version
  from public.folder_versions
  where operation_id = p_operation_id;

  if found then
    if v_version.folder_id <> p_folder_id
       or v_version.project_id <> p_project_id
       or v_version.base_revision <> p_base_revision
       or v_version.device_id <> p_device_id
       or v_version.parent_folder_id is distinct from p_parent_folder_id
       or v_version.name <> p_name
       or v_version.is_deleted <> p_is_deleted
       or v_version.created_by <> v_user_id then
      raise exception using errcode = 'P0001', message = 'OPERATION_ID_REUSED';
    end if;

    return pg_catalog.jsonb_build_object(
      'status', 'replayed',
      'folder_id', v_version.folder_id,
      'version_id', v_version.version_id,
      'operation_id', v_version.operation_id,
      'operation_kind', v_version.operation_kind,
      'revision', v_version.revision,
      'parent_folder_id', v_version.parent_folder_id,
      'name', v_version.name,
      'is_deleted', v_version.is_deleted,
      'committed_at', v_version.created_at
    );
  end if;

  select * into v_folder
  from public.folders
  where folder_id = p_folder_id
  for update;
  v_folder_exists := found;

  if p_parent_folder_id is not null then
    select * into v_parent
    from public.folders
    where folder_id = p_parent_folder_id
      and project_id = p_project_id
    for update;

    if not found or v_parent.is_deleted then
      raise exception using errcode = 'P0001', message = 'PARENT_FOLDER_NOT_FOUND';
    end if;

    with recursive ancestors as (
      select folder.folder_id, folder.parent_folder_id
      from public.folders folder
      where folder.folder_id = p_parent_folder_id
        and folder.project_id = p_project_id
      union all
      select parent.folder_id, parent.parent_folder_id
      from public.folders parent
      join ancestors child on parent.folder_id = child.parent_folder_id
      where parent.project_id = p_project_id
    )
    select exists (
      select 1 from ancestors where folder_id = p_folder_id
    ) into v_cycle;

    if v_cycle then
      raise exception using errcode = 'P0001', message = 'FOLDER_CYCLE';
    end if;
  end if;

  if p_base_revision = 0 then
    if v_folder_exists then
      raise exception using errcode = 'P0001', message = 'FOLDER_ALREADY_EXISTS';
    end if;
    if p_is_deleted then
      raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
    end if;
    if exists (
      select 1
      from public.folders sibling
      where sibling.project_id = p_project_id
        and sibling.parent_folder_id is not distinct from p_parent_folder_id
        and pg_catalog.lower(sibling.name) = pg_catalog.lower(p_name)
        and not sibling.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NAME_CONFLICT';
    end if;

    v_revision := 1;
    v_kind := 'create';
    insert into public.folders (
      folder_id, project_id, parent_folder_id, name, revision,
      is_deleted, deleted_at, created_by, updated_by, created_at, updated_at
    ) values (
      p_folder_id, p_project_id, p_parent_folder_id, p_name, v_revision,
      false, null, v_user_id, v_user_id, v_now, v_now
    );
  else
    if not v_folder_exists or v_folder.project_id <> p_project_id then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_FOUND';
    end if;
    if v_folder.revision <> p_base_revision then
      raise exception using
        errcode = 'P0001',
        message = 'REVISION_CONFLICT',
        detail = pg_catalog.jsonb_build_object(
          'current_revision', v_folder.revision,
          'parent_folder_id', v_folder.parent_folder_id,
          'name', v_folder.name,
          'is_deleted', v_folder.is_deleted
        )::text;
    end if;
    if p_is_deleted and exists (
      select 1
      from public.folders child
      where child.project_id = p_project_id
        and child.parent_folder_id = p_folder_id
        and not child.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NOT_EMPTY';
    end if;
    if not p_is_deleted and exists (
      select 1
      from public.folders sibling
      where sibling.project_id = p_project_id
        and sibling.parent_folder_id is not distinct from p_parent_folder_id
        and sibling.folder_id <> p_folder_id
        and pg_catalog.lower(sibling.name) = pg_catalog.lower(p_name)
        and not sibling.is_deleted
    ) then
      raise exception using errcode = 'P0001', message = 'FOLDER_NAME_CONFLICT';
    end if;

    v_revision := v_folder.revision + 1;
    v_kind := case
      when not v_folder.is_deleted and p_is_deleted then 'delete'
      when v_folder.is_deleted and not p_is_deleted then 'restore'
      when v_folder.parent_folder_id is distinct from p_parent_folder_id then 'move'
      when v_folder.name <> p_name then 'rename'
      else 'update'
    end;
  end if;

  insert into public.folder_versions (
    folder_id, project_id, revision, base_revision, operation_id, device_id,
    operation_kind, parent_folder_id, name, is_deleted, created_by, created_at
  ) values (
    p_folder_id, p_project_id, v_revision, p_base_revision, p_operation_id,
    p_device_id, v_kind, p_parent_folder_id, p_name, p_is_deleted,
    v_user_id, v_now
  )
  returning * into v_version;

  update public.folders
  set parent_folder_id = p_parent_folder_id,
      name = p_name,
      revision = v_revision,
      current_version_id = v_version.version_id,
      is_deleted = p_is_deleted,
      deleted_at = case when p_is_deleted then v_now else null end,
      updated_by = v_user_id,
      updated_at = v_now
  where folder_id = p_folder_id;

  return pg_catalog.jsonb_build_object(
    'status', 'committed',
    'folder_id', v_version.folder_id,
    'version_id', v_version.version_id,
    'operation_id', v_version.operation_id,
    'operation_kind', v_version.operation_kind,
    'revision', v_version.revision,
    'parent_folder_id', v_version.parent_folder_id,
    'name', v_version.name,
    'is_deleted', v_version.is_deleted,
    'committed_at', v_version.created_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_project_status(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_project public.projects%rowtype;
  v_is_member boolean := false;
  v_purged_owner uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  select * into v_project
  from public.projects
  where project_id = p_project_id;

  if found then
    select exists (
      select 1
      from public.project_members member
      where member.project_id = p_project_id
        and member.user_id = v_user_id
    ) into v_is_member;

    if v_project.owner_id <> v_user_id and not v_is_member then
      raise exception using errcode = 'P0001', message = 'FORBIDDEN';
    end if;

    return pg_catalog.jsonb_build_object(
      'project_id', v_project.project_id,
      'state', case
        when v_project.trashed_at is null then 'active'
        else 'trashed'
      end,
      'name', v_project.name,
      'updated_at', v_project.updated_at,
      'trashed_at', v_project.trashed_at
    );
  end if;

  select owner_id into v_purged_owner
  from private.project_purge_tombstones
  where project_id = p_project_id;

  if found and v_purged_owner = v_user_id then
    return pg_catalog.jsonb_build_object(
      'project_id', p_project_id,
      'state', 'purged'
    );
  end if;

  raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_trashed_projects()
 RETURNS TABLE(project_id uuid, name text, trashed_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  return query
  select p.project_id, p.name, p.trashed_at, p.updated_at
  from public.projects p
  where p.owner_id = v_user_id
    and p.trashed_at is not null
  order by p.trashed_at desc, p.name, p.project_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.purge_project(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_tombstone_owner uuid;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    select owner_id into v_tombstone_owner
    from private.project_purge_tombstones
    where project_id = p_project_id;

    if found and v_tombstone_owner = v_user_id then
      return pg_catalog.jsonb_build_object(
        'status', 'purged',
        'project_id', p_project_id,
        'already_purged', true
      );
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;
  if v_project.trashed_at is null then
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_TRASHED';
  end if;

  insert into private.project_purge_tombstones (
    project_id, owner_id, purged_by, purged_at
  ) values (
    p_project_id, v_project.owner_id, v_user_id, v_now
  )
  on conflict (project_id) do nothing;

  delete from public.projects where project_id = p_project_id;

  return pg_catalog.jsonb_build_object(
    'status', 'purged',
    'project_id', p_project_id,
    'already_purged', false,
    'purged_at', v_now
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.restore_project(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
  v_was_trashed boolean;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1 from private.project_purge_tombstones
      where project_id = p_project_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  v_was_trashed := v_project.trashed_at is not null;
  if v_was_trashed then
    update public.projects
    set trashed_at = null,
        trashed_by = null,
        updated_at = v_now
    where project_id = p_project_id
    returning * into v_project;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'active',
    'project_id', v_project.project_id,
    'name', v_project.name,
    'restored', v_was_trashed
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.trash_project(p_project_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_now timestamptz := pg_catalog.transaction_timestamp();
  v_project public.projects%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;
  if p_project_id is null then
    raise exception using errcode = 'P0001', message = 'INVALID_ARGUMENT';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('project:' || p_project_id::text, 0)
  );

  select * into v_project
  from public.projects
  where project_id = p_project_id
  for update;

  if not found then
    if exists (
      select 1 from private.project_purge_tombstones
      where project_id = p_project_id
    ) then
      raise exception using errcode = 'P0001', message = 'PROJECT_PURGED';
    end if;
    raise exception using errcode = 'P0001', message = 'PROJECT_NOT_FOUND';
  end if;
  if v_project.owner_id <> v_user_id then
    raise exception using errcode = 'P0001', message = 'FORBIDDEN';
  end if;

  if v_project.trashed_at is null then
    update public.projects
    set trashed_at = v_now,
        trashed_by = v_user_id,
        updated_at = v_now
    where project_id = p_project_id
    returning * into v_project;

    delete from public.edit_leases lease
    using public.documents document
    where document.project_id = p_project_id
      and lease.document_id = document.document_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'status', 'trashed',
    'project_id', v_project.project_id,
    'name', v_project.name,
    'trashed_at', v_project.trashed_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.touch_editor_locks_locked_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
NEW.locked_at = timezone('utc'::text, now());
RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.touch_writing_contents_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
NEW.updated_at = timezone('utc'::text, now());
RETURN NEW;
END;
$function$;

revoke all on function private.is_valid_entry_name(text) from public;
revoke all on table private.project_purge_tombstones from public, anon, authenticated, service_role;

alter table private.project_purge_tombstones enable row level security;

alter table public.folders enable row level security;
alter table public.folders force row level security;
alter table public.folder_versions enable row level security;
alter table public.folder_versions force row level security;

create policy folders_read_members
on public.folders
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

create policy folder_versions_read_members
on public.folder_versions
for select
to authenticated
using (private.has_project_role(project_id, (select auth.uid()), 'viewer'));

revoke all on table public.folders from anon, authenticated;
revoke all on table public.folder_versions from anon, authenticated;
grant select on table public.folders to authenticated;
grant select on table public.folder_versions to authenticated;

grant all on table public.projects to service_role;
grant all on table public.project_members to service_role;
grant all on table public.documents to service_role;
grant all on table public.document_versions to service_role;
grant all on table public.edit_leases to service_role;
grant all on table public.folders to service_role;
grant all on table public.folder_versions to service_role;

revoke all on function public.commit_folder(uuid, uuid, bigint, uuid, uuid, uuid, text, boolean) from public, anon;
revoke all on function public.get_project_status(uuid) from public, anon;
revoke all on function public.list_trashed_projects() from public, anon;
revoke all on function public.purge_project(uuid) from public, anon;
revoke all on function public.restore_project(uuid) from public, anon;
revoke all on function public.trash_project(uuid) from public, anon;

grant execute on function public.commit_folder(uuid, uuid, bigint, uuid, uuid, uuid, text, boolean) to authenticated, service_role;
grant execute on function public.get_project_status(uuid) to authenticated, service_role;
grant execute on function public.list_trashed_projects() to authenticated, service_role;
grant execute on function public.purge_project(uuid) to authenticated, service_role;
grant execute on function public.restore_project(uuid) to authenticated, service_role;
grant execute on function public.trash_project(uuid) to authenticated, service_role;

grant execute on function public.ensure_project(uuid, text) to service_role;
grant execute on function public.acquire_edit_lease(uuid, uuid, integer) to service_role;
grant execute on function public.renew_edit_lease(uuid, uuid, uuid, integer) to service_role;
grant execute on function public.release_edit_lease(uuid, uuid, uuid) to service_role;
grant execute on function public.get_edit_lease(uuid, uuid) to service_role;
grant execute on function public.commit_document(uuid, uuid, bigint, uuid, uuid, text, text, boolean, uuid) to service_role;

comment on table public.folders is
  'Stable cross-device folder projection. Writes only through commit_folder.';
comment on table public.folder_versions is
  'Immutable folder history and operation-id idempotency log.';

do $publication$
begin
  if exists (
    select 1 from pg_catalog.pg_publication
    where pubname = 'supabase_realtime'
  ) and not exists (
    select 1
    from pg_catalog.pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'folders'
  ) then
    alter publication supabase_realtime add table public.folders;
  end if;
end;
$publication$;

commit;
