begin;

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
  updated_at timestamptz not null default pg_catalog.transaction_timestamp()
);

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

create or replace function private.has_project_role(
  p_project_id uuid,
  p_user_id uuid,
  p_minimum_role text default 'viewer'
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
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
        and (
          p.owner_id = p_user_id
          or case p_minimum_role
            when 'owner' then m.role = 'owner'
            when 'editor' then m.role in ('owner', 'editor')
            when 'viewer' then m.role in ('owner', 'editor', 'viewer')
          end
        )
    );
$$;

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

commit;
