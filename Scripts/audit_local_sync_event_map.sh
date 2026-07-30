#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repository_root"

event_source="WriterPad/Domain/Protocols/FutureChangeNotifying.swift"
event_map="Docs/LocalToSyncEventMap.md"

fail() {
    echo "8-3 event map audit failed: $1" >&2
    exit 1
}

for event in appLaunched documentSaved manuscriptVolumeCreated documentRestored \
    documentTrashed documentRestoredFromTrash documentPermanentlyDeleted; do
    rg -q "case $event" "$event_source" \
        || fail "current LocalChangeEvent case $event is missing from the audit baseline"
    rg -q "\`$event\`" "$event_map" \
        || fail "LocalChangeEvent case $event is absent from the mapping document"
done

rg -q 'func record\(_ event: LocalChangeEvent\) async$' "$event_source" \
    || fail "FutureChangeNotifying is no longer the audited nonthrowing, no-result boundary"

if rg -q \
    'case (documentCreated|documentRenamed|documentMoved|binderReordered|projectCreated|projectRenamed|trashEmptied)' \
    "$event_source"; then
    fail "LocalChangeEvent gained an event that is not part of the audited seven-case baseline"
fi

for function_name in create rename move reorder moveToTrash restoreFromTrash \
    permanentlyDelete emptyTrash; do
    rg -q "func $function_name\\(" \
        WriterPad/Data/Local/LocalBinderCommandService.swift \
        WriterPad/Data/Local/LocalBinderCommandServiceSupport.swift \
        || fail "binder mutation $function_name is absent"
done

for function_name in createProject renameProject reorderProjects confirmDeletion \
    moveToDeletedList restoreFromDeletedList permanentlyDelete; do
    rg -q "func $function_name\\(" WriterPad/Data/Local/LocalProjectManager.swift \
        || fail "project mutation $function_name is absent"
done

for required_text in \
    'v2 문서 commit' \
    '숨은 tree-order commit' \
    '숨은 trash-purge commit' \
    '프로젝트 `ensure_project`' \
    '로컬 전용' \
    '서버 계약이 없어 보류' \
    'localSavedButNotQueued' \
    'document UUID별 직렬 lane 하나'; do
    rg -F -q "$required_text" "$event_map" \
        || fail "mapping policy is missing: $required_text"
done

rg -q 'if child_names:' 참조파일/writing_tree.py \
    || fail "Windows tree-order empty-parent behavior changed"
rg -F -q 'self._v2_wpm.project_settings["tree_order"] = merged_order' \
    참조파일/sync_manager.py \
    || fail "Windows remote tree-order application boundary changed"

echo "8-3 event map audit passed: all local mutation classes and known gaps are documented."
