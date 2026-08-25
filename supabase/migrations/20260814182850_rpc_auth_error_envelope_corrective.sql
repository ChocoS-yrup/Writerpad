begin;

-- Additive corrective migration for Stage 7 SERVER_CONTRACT_MISMATCH.
-- The already-applied migrations remain immutable. The wrappers preserve the
-- released implementations while converting only their outer auth boundary
-- into the canonical JSON failure envelope.

do $rename_atomic$
begin
  if pg_catalog.to_regprocedure('public.atomic_structure_commit_legacy(jsonb)') is null
     and pg_catalog.to_regprocedure('public.atomic_structure_commit(jsonb)') is not null then
    alter function public.atomic_structure_commit(jsonb)
      rename to atomic_structure_commit_legacy;
  end if;
end;
$rename_atomic$;

do $rename_document$
begin
  if pg_catalog.to_regprocedure('public.document_commit_legacy(jsonb)') is null
     and pg_catalog.to_regprocedure('public.document_commit(jsonb)') is not null then
    alter function public.document_commit(jsonb)
      rename to document_commit_legacy;
  end if;
end;
$rename_document$;

create or replace function public.atomic_structure_commit(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch_id uuid;
  v_payload_sha text;
  v_error_code text;
begin
  -- Parse only the response identity before checking auth. Do not trust any
  -- authorization metadata from the request; auth.uid() is authoritative.
  begin
    v_batch_id := (p_request->'batch'->>'batch_id')::uuid;
    v_payload_sha := p_request->'batch'->>'batch_payload_sha256';
  exception when others then
    v_batch_id := null;
    v_payload_sha := null;
  end;

  if auth.uid() is null then
    return private.atomic_failure(
      v_batch_id, v_payload_sha, 'AUTH_REQUIRED',
      'authentication is required', null
    );
  end if;

  begin
    return public.atomic_structure_commit_legacy(p_request);
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
    if v_error_code = 'FORBIDDEN' then
      return private.atomic_failure(
        v_batch_id, v_payload_sha, 'FORBIDDEN',
        'the caller is not an editor of this project', null
      );
    end if;
    raise;
  end;
end;
$$;

create or replace function public.document_commit(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_batch_id uuid;
  v_payload_sha text;
  v_error_code text;
begin
  -- Parse only the response identity before checking auth. Do not trust any
  -- authorization metadata from the request; auth.uid() is authoritative.
  begin
    v_batch_id := (p_request->'batch'->>'batch_id')::uuid;
    v_payload_sha := p_request->'batch'->>'batch_payload_sha256';
  exception when others then
    v_batch_id := null;
    v_payload_sha := null;
  end;

  if auth.uid() is null then
    return private.document_failure(
      v_batch_id, v_payload_sha, 'AUTH_REQUIRED',
      'authentication is required', null
    );
  end if;

  begin
    return public.document_commit_legacy(p_request);
  exception when sqlstate 'P0001' then
    v_error_code := sqlerrm;
    if v_error_code = 'FORBIDDEN' then
      return private.document_failure(
        v_batch_id, v_payload_sha, 'FORBIDDEN',
        'the caller is not an editor of this project', null
      );
    end if;
    raise;
  end;
end;
$$;

-- The renamed implementations are not public entry points. The wrappers are
-- the only functions opened to anon; authenticated retains the normal path.
revoke all on function public.atomic_structure_commit_legacy(jsonb)
  from public, anon, authenticated;
revoke all on function public.document_commit_legacy(jsonb)
  from public, anon, authenticated;
revoke all on function public.atomic_structure_commit(jsonb)
  from public;
revoke all on function public.document_commit(jsonb)
  from public;
grant execute on function public.atomic_structure_commit(jsonb)
  to anon, authenticated;
grant execute on function public.document_commit(jsonb)
  to anon, authenticated;

comment on function public.atomic_structure_commit(jsonb) is
  'Contract 0.3.0 atomic structure commit with canonical auth failure envelopes.';
comment on function public.document_commit(jsonb) is
  'Contract 0.3.0 document commit with canonical auth failure envelopes.';

commit;
