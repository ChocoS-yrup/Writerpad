#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

baseline_sql="참조파일/20260714000000_supabase_v2_protocol.sql"
support_sql="참조파일/20260714010000_windows_v2_client_support.sql"
windows_client="참조파일/sync_manager.py"

fail() {
    echo "8-2 contract audit failed: $1" >&2
    exit 1
}

for table in projects project_members documents document_versions edit_leases; do
    rg -q "create table public\\.$table" "$baseline_sql" \
        || fail "missing public.$table"
done

for rpc in ensure_project acquire_edit_lease renew_edit_lease release_edit_lease \
    get_edit_lease commit_document; do
    rg -q "create or replace function public\\.$rpc" "$baseline_sql" \
        || fail "missing public.$rpc"
done

for code in AUTH_REQUIRED FORBIDDEN INVALID_ARGUMENT DOCUMENT_NOT_FOUND \
    DOCUMENT_ALREADY_EXISTS REVISION_CONFLICT OPERATION_ID_REUSED LEASE_REQUIRED \
    LEASE_CONFLICT LEASE_EXPIRED PATH_CONFLICT; do
    rg -q "message = '$code'" "$baseline_sql" \
        || fail "missing stable error code $code"
    rg -q "\"$code\"" "$windows_client" \
        || fail "Windows client does not recognize $code"
done

rg -q 'pg_catalog\.octet_length\(p_content\) > 10485760' "$baseline_sql" \
    || fail "commit content limit is not 10 MiB"
rg -q 'pg_catalog\.length\(p_path\) <= 1024' "$baseline_sql" \
    || fail "relative path limit is not 1,024 characters"
rg -q "alter table public\\.edit_leases force row level security" "$baseline_sql" \
    || fail "edit_leases does not force RLS"
if rg -q 'grant select on table public\.edit_leases' "$baseline_sql"; then
    fail "lease tokens are directly selectable"
fi

for field in status document_id version_id operation_id operation_kind revision \
    relative_path is_deleted content_hash committed_at; do
    rg -q "'$field'" "$baseline_sql" \
        || fail "commit response field $field is absent"
done

for rpc in ensure_project acquire_edit_lease release_edit_lease commit_document; do
    rg -q "rpc\\(\"$rpc\"" "$windows_client" \
        || fail "Windows client does not call $rpc"
done
rg -q 'table\("documents"\)' "$windows_client" \
    || fail "Windows client does not read document snapshots"
rg -q 'TREE_ORDER_DOCUMENT_PATH = "__antigravity__/tree-order\.json"' "$windows_client" \
    || fail "tree-order hidden document path changed"
rg -q 'TRASH_PURGE_DOCUMENT_PATH = "__antigravity__/trash-purge\.json"' "$windows_client" \
    || fail "trash-purge hidden document path changed"

first_definition=$(mktemp)
final_definition=$(mktemp)
trap 'rm -f "$first_definition" "$final_definition"' EXIT HUP INT TERM

awk '
    /^create or replace function public\.ensure_project/ { copying = 1 }
    copying { print }
    copying && /^\$\$;/ { exit }
' "$baseline_sql" >"$first_definition"
awk '
    /^create or replace function public\.ensure_project/ { copying = 1 }
    copying { print }
    copying && /^\$\$;/ { exit }
' "$support_sql" >"$final_definition"

cmp -s "$first_definition" "$final_definition" \
    || fail "the support SQL ensure_project definition differs from the baseline copy"

echo "8-2 contract audit passed: SQL and Windows v2 observable boundaries match."
