import json
import tempfile
import unittest
import uuid
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from PyQt6.QtCore import Qt

from mode_writing import WritingModeWidget
from project_manager_writing import WritingProjectManager
from sync_manager import (
    LockWorker,
    TRASH_PURGE_DOCUMENT_PATH,
    TREE_ORDER_DOCUMENT_PATH,
    SyncManager,
    V2QueueWorker,
    is_live_document_path,
)
from sync_v2_store import SyncV2Store
from three_way_merge import three_way_merge
from writing_tree import WritingTreeMixin


class ThreeWayMergeTestCase(unittest.TestCase):
    def test_non_overlapping_edits_merge_without_markers(self):
        base = "첫 줄\n둘째 줄\n셋째 줄\n"
        local = "첫 줄 수정\n둘째 줄\n셋째 줄\n"
        remote = "첫 줄\n둘째 줄\n셋째 줄 수정\n"

        result = three_way_merge(base, local, remote)

        self.assertFalse(result.has_conflicts)
        self.assertEqual(result.content, "첫 줄 수정\n둘째 줄\n셋째 줄 수정\n")

    def test_overlapping_edits_keep_all_three_versions(self):
        result = three_way_merge("문장\n", "내 문장\n", "서버 문장\n")

        self.assertTrue(result.has_conflicts)
        self.assertEqual(result.conflict_count, 1)
        self.assertIn("<<<<<<< 내 로컬 편집본", result.content)
        self.assertIn("||||||| 마지막 공통본", result.content)
        self.assertIn(">>>>>>> 서버 최신본", result.content)

    def test_line_edit_and_adjacent_line_insertion_merge_cleanly(self):
        base = "이름 변경 테스트\nA가 파일 이름을 바꿉니다.\nB가 이 줄을 수정합니다.\n"
        local = base + "강제 종료 후에도 남아야 하는 문장"
        remote = (
            "이름 변경 테스트\n"
            "A가 파일 이름을 바꿉니다.\n"
            "B가 이름변경과 동시에 수정했습니다."
        )

        result = three_way_merge(base, local, remote)

        self.assertFalse(result.has_conflicts)
        self.assertEqual(
            result.content,
            remote + "\n강제 종료 후에도 남아야 하는 문장\n",
        )


class SyncV2StoreTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.db_path = str(Path(self.temp.name, "sync.sqlite3"))
        self.store = SyncV2Store(self.db_path)
        self.context = self.store.configure_project(
            str(Path(self.temp.name, "집필모드")), "테스트 작품"
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_queue_survives_restart_and_keeps_operation_id(self):
        operation = self.store.enqueue(
            self.context, "메인/원고/001화.txt", "영구 보관할 내용"
        )

        reopened = SyncV2Store(self.db_path)
        queued = reopened.next_ready_operation(self.context["local_key"])

        self.assertEqual(queued["operation_id"], operation["operation_id"])
        self.assertEqual(queued["content"], "영구 보관할 내용")

    def test_force_kill_resets_inflight_operation_to_pending_with_same_id(self):
        operation = self.store.enqueue(
            self.context, "메인/원고/강제종료.txt", "종료 직전 내용"
        )
        self.store.mark_attempt(operation["operation_id"])
        self.assertEqual(self.store.operation(operation["operation_id"])["status"], "inflight")

        reopened = SyncV2Store(self.db_path)
        recovered = reopened.next_ready_operation(self.context["local_key"])

        self.assertEqual(recovered["operation_id"], operation["operation_id"])
        self.assertEqual(recovered["status"], "pending")

    def test_two_offline_profiles_keep_independent_durable_queues(self):
        first_path = str(Path(self.temp.name, "first.sqlite3"))
        other_path = str(Path(self.temp.name, "other.sqlite3"))
        first = SyncV2Store(first_path)
        other = SyncV2Store(other_path)
        shared_project_id = str(uuid.uuid4())
        context_a = first.configure_project(
            str(Path(self.temp.name, "A", "집필모드")), "공유 작품", shared_project_id
        )
        context_b = other.configure_project(
            str(Path(self.temp.name, "B", "집필모드")), "공유 작품", shared_project_id
        )
        shared_document_id = str(uuid.uuid4())
        first.ensure_document(
            context_a["local_key"], "메인/원고/001화.txt", "공통본", shared_document_id
        )
        other.ensure_document(
            context_b["local_key"], "메인/원고/001화.txt", "공통본", shared_document_id
        )

        queued_a = first.enqueue(context_a, "메인/원고/001화.txt", "A 오프라인 편집")
        queued_b = other.enqueue(context_b, "메인/원고/001화.txt", "B 오프라인 편집")

        self.assertNotEqual(queued_a["operation_id"], queued_b["operation_id"])
        self.assertEqual(SyncV2Store(first_path).counts(context_a["local_key"])["pending"], 1)
        self.assertEqual(SyncV2Store(other_path).counts(context_b["local_key"])["pending"], 1)

    def test_success_promotes_next_operation_to_returned_revision(self):
        first = self.store.enqueue(self.context, "메인/원고/001화.txt", "첫 저장")
        second = self.store.enqueue(self.context, "메인/원고/001화.txt", "둘째 저장")
        self.assertIsNone(second["base_revision"])

        self.store.mark_success(first["operation_id"], {
            "revision": 1,
            "content_hash": "a" * 64,
        })
        promoted = self.store.operation(second["operation_id"])

        self.assertEqual(promoted["base_revision"], 1)
        self.assertEqual(promoted["base_content"], "첫 저장")

    def test_uuid_survives_file_and_folder_moves(self):
        original = self.store.ensure_document(
            self.context["local_key"], "메인/원고/1권/001화.txt"
        )

        moved = self.store.move_local_path(
            self.context["local_key"], "메인/원고/1권", "메인/원고/2권"
        )
        current = self.store.get_document(
            self.context["local_key"], "메인/원고/2권/001화.txt"
        )

        self.assertEqual(len(moved), 1)
        self.assertEqual(current["document_id"], original["document_id"])

    def test_newer_remote_snapshot_updates_clean_document_and_path(self):
        document = self.store.ensure_document(
            self.context["local_key"], "메인/메모장/예전이름.txt", "기준본"
        )

        applied = self.store.apply_remote_snapshot(
            self.context,
            document["document_id"],
            "메인/메모장/새이름.txt",
            "서버 최신본",
            4,
            local_path="메인/메모장/새이름.txt",
        )

        current = self.store.get_document_by_id(document["document_id"])
        self.assertTrue(applied["applied"])
        self.assertEqual(applied["previous_path"], "메인/메모장/예전이름.txt")
        self.assertEqual(current["local_path"], "메인/메몥/새이름.txt".replace("메몥", "메모장"))
        self.assertEqual(current["revision"], 4)
        self.assertEqual(current["base_content"], "서버 최신본")

    def test_remote_snapshot_never_replaces_document_with_pending_work(self):
        queued = self.store.enqueue(
            self.context, "메인/메모장/대기중.txt", "로컬 편집본"
        )

        applied = self.store.apply_remote_snapshot(
            self.context,
            queued["document_id"],
            "메인/메모장/대기중.txt",
            "서버가 더 최신",
            9,
        )

        current = self.store.get_document_by_id(queued["document_id"])
        self.assertFalse(applied["applied"])
        self.assertEqual(applied["reason"], "active_operations")
        self.assertEqual(current["revision"], 0)

    def test_clean_rebase_uses_latest_merged_snapshot_and_cancels_stale_dependents(self):
        created = self.store.enqueue(self.context, "메인/원고/001화.txt", "공통본")
        self.store.mark_success(created["operation_id"], {
            "revision": 1,
            "content_hash": "a" * 64,
        })
        first = self.store.enqueue(self.context, "메인/원고/001화.txt", "로컬 1")
        stale_dependent = self.store.enqueue(self.context, "메인/원고/001화.txt", "로컬 최신")

        self.store.rebase_clean_merge(first["operation_id"], 2, "서버 변경", "자동 병합본")

        rebased = self.store.operation(first["operation_id"])
        cancelled = self.store.operation(stale_dependent["operation_id"])
        self.assertEqual(rebased["base_revision"], 2)
        self.assertEqual(rebased["content"], "자동 병합본")
        self.assertEqual(cancelled["status"], "cancelled")

    def test_remote_rename_rebase_keeps_uuid_and_changes_only_server_path(self):
        original = self.store.ensure_document(
            self.context["local_key"], "메인/원고/옛이름.txt", "공통본"
        )
        created = self.store.enqueue(self.context, "메인/원고/옛이름.txt", "공통본")
        self.store.mark_success(created["operation_id"], {
            "revision": 1,
            "content_hash": "a" * 64,
        })
        edited = self.store.enqueue(self.context, "메인/원고/옛이름.txt", "로컬 수정")
        self.store.move_local_path(
            self.context["local_key"], "메인/원고/옛이름.txt", "메인/원고/새이름.txt"
        )
        self.store.rebase_clean_merge(
            edited["operation_id"], 2, "서버 수정", "자동 병합본",
            remote_path="메인/원고/새이름.txt",
        )

        document = self.store.get_document(
            self.context["local_key"], "메인/원고/새이름.txt"
        )
        operation = self.store.operation(edited["operation_id"])
        self.assertEqual(document["document_id"], original["document_id"])
        self.assertEqual(document["server_path"], "메인/원고/새이름.txt")
        self.assertEqual(operation["relative_path"], "메인/원고/새이름.txt")

    def test_simultaneous_overlapping_save_is_kept_as_conflict(self):
        created = self.store.enqueue(self.context, "메인/원고/동시저장.txt", "공통 문장\n")
        self.store.mark_success(created["operation_id"], {
            "revision": 1,
            "content_hash": "a" * 64,
        })
        local = self.store.enqueue(self.context, "메인/원고/동시저장.txt", "A 문장\n")
        merged = three_way_merge("공통 문장\n", "A 문장\n", "B 문장\n")
        self.assertTrue(merged.has_conflicts)
        self.store.mark_conflict(
            local["operation_id"], 2, "메인/원고/동시저장.txt",
            "B 문장\n", merged.content, "A 문장\n",
        )

        self.assertEqual(self.store.operation(local["operation_id"])["status"], "conflict")
        document = self.store.get_document(
            self.context["local_key"], "메인/원고/동시저장.txt"
        )
        self.assertEqual(document["conflict_local"], "A 문장\n")
        self.assertEqual(document["conflict_remote"], "B 문장\n")

    def test_new_save_after_conflict_uses_remote_revision_as_new_base(self):
        created = self.store.enqueue(self.context, "메인/원고/001화.txt", "공통본")
        self.store.mark_success(created["operation_id"], {
            "revision": 1,
            "content_hash": "a" * 64,
        })
        conflicted = self.store.enqueue(self.context, "메인/원고/001화.txt", "내 수정")
        self.store.mark_conflict(
            conflicted["operation_id"], 2, "메인/원고/001화.txt",
            "서버 수정", "충돌 표시 병합본", "내 수정"
        )

        resolved = self.store.enqueue(self.context, "메인/원고/001화.txt", "직접 해결한 본문")

        self.assertEqual(resolved["base_revision"], 2)
        self.assertEqual(resolved["base_content"], "서버 수정")
        self.assertEqual(self.store.operation(conflicted["operation_id"])["status"], "cancelled")


class _Response:
    def __init__(self, data):
        self.data = data


class _RpcCall:
    def __init__(self, client, name, params):
        self.client = client
        self.name = name
        self.params = params

    def execute(self):
        self.client.calls.append((self.name, self.params))
        if self.name == "ensure_project":
            return _Response({"project_id": self.params["p_project_id"]})
        if self.name == "acquire_edit_lease":
            return _Response({"lease_token": str(uuid.uuid4())})
        if self.name == "release_edit_lease":
            return _Response(True)
        if self.name == "commit_document":
            return _Response({
                "status": "committed",
                "revision": self.params["p_base_revision"] + 1,
                "content_hash": "b" * 64,
            })
        raise AssertionError(self.name)


class _FakeClient:
    def __init__(self):
        self.calls = []

    def rpc(self, name, params):
        return _RpcCall(self, name, params)


class SyncV2RpcTestCase(unittest.TestCase):
    def test_background_commit_releases_lease_after_document_switch(self):
        manager = SyncManager()
        previous = (
            manager.supabase,
            manager._v2_device_id,
            dict(manager._v2_leases),
            manager._v2_active_paths_provider,
        )
        document_id = str(uuid.uuid4())
        client = _FakeClient()
        try:
            manager.supabase = client
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_leases = {document_id: "lease-token"}
            manager.set_active_document_paths_provider(
                lambda: ["메인/메모장/지금열린문서.txt"]
            )

            manager._finalize_v2_operation_lease("committed", {
                "document_id": document_id,
                "local_path": "메인/메모장/이전에열린문서.txt",
                "is_deleted": False,
            })

            self.assertNotIn(document_id, manager._v2_leases)
            self.assertEqual(client.calls[0][0], "release_edit_lease")
        finally:
            (
                manager.supabase,
                manager._v2_device_id,
                previous_leases,
                manager._v2_active_paths_provider,
            ) = previous
            manager._v2_leases = previous_leases

    def test_active_document_keeps_lease_for_heartbeat(self):
        manager = SyncManager()
        previous = (
            manager.supabase,
            manager._v2_device_id,
            dict(manager._v2_leases),
            manager._v2_active_paths_provider,
        )
        document_id = str(uuid.uuid4())
        client = _FakeClient()
        active_path = "메인/메모장/계속편집중.txt"
        try:
            manager.supabase = client
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_leases = {document_id: "lease-token"}
            manager.set_active_document_paths_provider(lambda: [active_path])

            manager._finalize_v2_operation_lease("committed", {
                "document_id": document_id,
                "local_path": active_path,
                "is_deleted": False,
            })

            self.assertEqual(manager._v2_leases[document_id], "lease-token")
            self.assertEqual(client.calls, [])
        finally:
            (
                manager.supabase,
                manager._v2_device_id,
                previous_leases,
                manager._v2_active_paths_provider,
            ) = previous
            manager._v2_leases = previous_leases

    def test_unchanged_synced_content_does_not_create_another_revision(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "중복 저장 방지 작품"
            wpm.writing_root_path = str(Path(temp_dir, "중복 저장 방지 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            relative_path = "메인/메모장/같은내용.txt"
            content = "이미 서버에 저장된 내용"
            self.assertTrue(wpm.write_text_file(relative_path, content))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(
                wpm, wpm.current_project, str(uuid.uuid4()), store=store
            )
            created = store.enqueue(manager._v2_context, relative_path, content)
            store.mark_success(created["operation_id"], {
                "revision": 1,
                "content_hash": "a" * 64,
            })
            callback = MagicMock()

            with patch.object(manager, "retry_pending_syncs") as retry:
                worker = manager.upload_content_async(
                    wpm,
                    wpm.current_project,
                    relative_path,
                    content,
                    callback=callback,
                )

            self.assertIsNone(worker)
            self.assertEqual(store.counts(manager._v2_context["local_key"])["total"], 0)
            self.assertIsNone(store.next_ready_operation(manager._v2_context["local_key"]))
            callback.assert_called_once_with(True, "", relative_path, 1)
            retry.assert_not_called()

    def test_v2_lock_worker_reuses_one_authenticated_profile_client(self):
        authenticated_client = object()
        manager = SimpleNamespace(
            is_v2_enabled=True,
            supabase=authenticated_client,
            check_and_acquire_lock=MagicMock(return_value=(True, "Lock acquired.")),
            get_file_updated_at=MagicMock(return_value=3),
        )
        worker = LockWorker(manager, "작품", "메인/메모장/문서.txt", "device-a")
        result = MagicMock()
        worker.finished.connect(result)

        with patch.object(
            SyncManager,
            "create_supabase_client",
            side_effect=AssertionError("v2에서 새 인증 클라이언트를 만들면 안 됩니다."),
        ):
            worker.run()

        manager.check_and_acquire_lock.assert_called_once_with(
            "작품",
            "메인/메모장/문서.txt",
            "device-a",
            client=authenticated_client,
        )
        result.assert_called_once_with(True, "Lock acquired.", 3)

    def test_existing_v2_project_recovers_three_new_unregistered_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "연속 생성 복구 작품"
            wpm.writing_root_path = str(Path(temp_dir, "연속 생성 복구 작품", "집필모드"))
            memo_dir = Path(wpm.writing_root_path, "메인", "메모장")
            memo_dir.mkdir(parents=True)
            wpm.project_settings = {}
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)

            for index in range(3):
                (memo_dir / f"새_문서 ({index}).txt").write_text("", encoding="utf-8")

            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)
            operations = []
            while True:
                operation = store.next_ready_operation(manager._v2_context["local_key"])
                if not operation:
                    break
                operations.append(operation)
                store.mark_attempt(operation["operation_id"])

            self.assertEqual(len(operations), 3)
            self.assertEqual(len({item["document_id"] for item in operations}), 3)
            self.assertEqual(
                {item["local_path"] for item in operations},
                {f"메인/메모장/새_문서 ({index}).txt" for index in range(3)},
            )

    def test_remote_tree_order_replaces_local_order_but_keeps_local_trash_order(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "순서 동기화 작품"
            wpm.writing_root_path = str(Path(temp_dir, "순서 동기화 작품", "집필모드"))
            wpm.settings_path = str(Path(wpm.writing_root_path, "설정.json"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            wpm.project_settings = {
                "tree_order": {
                    "메인/메모장": ["로컬.txt"],
                    "메인/휴지통": ["로컬휴지통.txt"],
                }
            }
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            document_id = str(uuid.uuid5(
                uuid.UUID(context["project_id"]), TREE_ORDER_DOCUMENT_PATH
            ))
            content = manager._tree_order_content({
                "메인/메모장": ["셋째.txt", "첫째.txt", "둘째.txt"],
                "메인/휴지통": ["서버휴지통.txt"],
            })

            changes = manager._apply_v2_remote_documents([{
                "document_id": document_id,
                "relative_path": TREE_ORDER_DOCUMENT_PATH,
                "content": content,
                "revision": 1,
                "is_deleted": False,
            }])

            self.assertEqual(changes[0]["kind"], "tree_order")
            self.assertEqual(
                wpm.project_settings["tree_order"]["메인/메모장"],
                ["셋째.txt", "첫째.txt", "둘째.txt"],
            )
            self.assertEqual(
                wpm.project_settings["tree_order"]["메인/휴지통"],
                ["로컬휴지통.txt"],
            )
            self.assertFalse(Path(wpm.writing_root_path, "__antigravity__").exists())

    def test_tree_order_is_queued_as_one_hidden_deterministic_v2_document(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                str(Path(temp_dir, "집필모드")), "순서 저장 작품", str(uuid.uuid4())
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_device_id = str(uuid.uuid4())

            with patch.object(manager, "retry_pending_syncs"):
                operation = manager.record_tree_order({
                    "메인/메모장": ["셋째.txt", "첫째.txt", "둘째.txt"],
                    "메인/휴지통": ["장치마다 이름이 다른 보관본.txt"],
                })

            expected_id = str(uuid.uuid5(
                uuid.UUID(context["project_id"]), TREE_ORDER_DOCUMENT_PATH
            ))
            payload = json.loads(operation["content"])
            self.assertEqual(operation["document_id"], expected_id)
            self.assertEqual(operation["relative_path"], TREE_ORDER_DOCUMENT_PATH)
            self.assertEqual(
                payload["tree_order"]["메인/메모장"],
                ["셋째.txt", "첫째.txt", "둘째.txt"],
            )
            self.assertNotIn("메인/휴지통", payload["tree_order"])

    def test_trash_paths_are_never_registered_as_live_cloud_documents(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "휴지통 제외 작품"
            wpm.writing_root_path = str(Path(temp_dir, "휴지통 제외 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/살아있는문서.txt"
            trash_path = "메인/휴지통/삭제된문서.txt"
            self.assertTrue(wpm.write_text_file(live_path, "정상 문서"))
            self.assertTrue(wpm.write_text_file(trash_path, "휴지통 보관본"))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)

            callback = MagicMock()
            manager.upload_content_async(
                wpm, wpm.current_project, trash_path, "휴지통 보관본", callback=callback
            )
            acquired, message = manager.check_and_acquire_lock(
                wpm.current_project, trash_path, "session-trash"
            )

            self.assertTrue(is_live_document_path(live_path))
            self.assertFalse(is_live_document_path(trash_path))
            self.assertIsNotNone(store.get_document(manager._v2_context["local_key"], live_path))
            self.assertIsNone(store.get_document(manager._v2_context["local_key"], trash_path))
            self.assertEqual(store.counts(manager._v2_context["local_key"])["total"], 0)
            self.assertFalse(acquired)
            self.assertIn("읽기 전용", message)
            callback.assert_called_once()

    def test_repeated_delete_and_restore_keep_one_document_uuid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "반복 삭제 작품"
            wpm.writing_root_path = str(Path(temp_dir, "반복 삭제 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/반복삭제.txt"
            content = "삭제와 복원을 반복해도 보존되어야 하는 내용"
            self.assertTrue(wpm.write_text_file(live_path, content))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)
            original = store.get_document(manager._v2_context["local_key"], live_path)
            created = store.enqueue(manager._v2_context, live_path, content)
            store.mark_success(created["operation_id"], {
                "revision": 1,
                "content_hash": "a" * 64,
            })
            next_revision = 2

            with patch.object(manager, "retry_pending_syncs"):
                for _ in range(3):
                    trash_path = wpm.move_to_trash(live_path)
                    moved_to_trash = manager.record_tombstone(live_path, trash_path)
                    delete_operation = store.next_ready_operation(manager._v2_context["local_key"])
                    self.assertEqual(moved_to_trash[0]["document_id"], original["document_id"])
                    self.assertTrue(delete_operation["is_deleted"])
                    self.assertEqual(delete_operation["relative_path"], live_path)
                    store.mark_success(delete_operation["operation_id"], {
                        "revision": next_revision,
                        "content_hash": "b" * 64,
                    })
                    next_revision += 1

                    restored_path = wpm.restore_from_trash(trash_path)
                    moved_to_live = manager.record_restore(trash_path, restored_path)
                    restore_operation = store.next_ready_operation(manager._v2_context["local_key"])
                    self.assertEqual(moved_to_live[0]["document_id"], original["document_id"])
                    self.assertFalse(restore_operation["is_deleted"])
                    self.assertEqual(restore_operation["relative_path"], live_path)
                    store.mark_success(restore_operation["operation_id"], {
                        "revision": next_revision,
                        "content_hash": "c" * 64,
                    })
                    next_revision += 1

            current = store.get_document(manager._v2_context["local_key"], live_path)
            self.assertEqual(current["document_id"], original["document_id"])
            self.assertFalse(current["is_deleted"])
            self.assertEqual(wpm.read_text_file(live_path), content)
            self.assertEqual(wpm.list_trash_items(), [])

    def test_delete_immediately_after_create_waits_behind_create_operation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "즉시 삭제 작품"
            wpm.writing_root_path = str(Path(temp_dir, "즉시 삭제 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/바로삭제.txt"
            self.assertTrue(wpm.write_text_file(live_path, ""))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)
            create_operation = store.enqueue(manager._v2_context, live_path, "")

            with patch.object(manager, "retry_pending_syncs"):
                trash_path = wpm.move_to_trash(live_path)
                moved = manager.record_tombstone(live_path, trash_path)

            self.assertEqual(moved[0]["document_id"], create_operation["document_id"])
            store.mark_success(create_operation["operation_id"], {
                "revision": 1,
                "content_hash": "d" * 64,
            })
            delete_operation = store.next_ready_operation(manager._v2_context["local_key"])
            self.assertIsNotNone(delete_operation)
            self.assertTrue(delete_operation["is_deleted"])
            self.assertEqual(delete_operation["base_revision"], 1)
            self.assertEqual(delete_operation["relative_path"], live_path)

    def test_reused_name_delete_relocates_around_stale_trash_uuid(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "휴지통 경로 충돌 작품"
            wpm.writing_root_path = str(Path(temp_dir, "휴지통 경로 충돌 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/반복이름.txt"
            stale_trash_path = "메인/휴지통/반복이름.txt"
            old_id = str(uuid.uuid4())
            new_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            store.apply_remote_snapshot(
                context, old_id, live_path, "예전 삭제본", 2,
                is_deleted=True, local_path=stale_trash_path,
            )
            store.apply_remote_snapshot(
                context, new_id, live_path, "현재 문서", 2,
                is_deleted=False, local_path=live_path,
            )
            self.assertTrue(wpm.write_text_file(live_path, "현재 문서"))
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())

            initial_trash_path = wpm.move_to_trash(live_path)
            self.assertEqual(initial_trash_path, stale_trash_path)
            with patch.object(manager, "retry_pending_syncs"):
                moved = manager.record_tombstone(live_path, initial_trash_path)

            self.assertEqual(len(moved), 1)
            relocated_path = moved[0]["local_path"]
            self.assertNotEqual(relocated_path, stale_trash_path)
            self.assertTrue(Path(wpm.writing_root_path, relocated_path).exists())
            self.assertEqual(store.get_document_by_id(old_id)["local_path"], stale_trash_path)
            self.assertEqual(store.get_document_by_id(new_id)["local_path"], relocated_path)
            queued = store.next_ready_operation(context["local_key"])
            self.assertTrue(queued["is_deleted"])
            self.assertEqual(queued["document_id"], new_id)
            trash_item = next(
                item for item in wpm.list_trash_items()
                if item["trash_path"] == relocated_path
            )
            self.assertEqual(trash_item["document_id"], new_id)

    def test_equal_revision_remote_tombstone_repairs_missing_trash_copy(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "휴지통 사본 복구 작품"
            wpm.writing_root_path = str(Path(temp_dir, "휴지통 사본 복구 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/사라진삭제본.txt"
            stale_trash_path = "메인/휴지통/사라진삭제본.txt"
            document_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            store.apply_remote_snapshot(
                context, document_id, live_path, "보존할 삭제 본문", 3,
                is_deleted=True, local_path=stale_trash_path,
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_protected_paths_provider = lambda: set()

            changes = manager._apply_v2_remote_documents([{
                "document_id": document_id,
                "relative_path": live_path,
                "content": "보존할 삭제 본문",
                "revision": 3,
                "is_deleted": True,
                "deleted_at": "2026-07-15T09:00:00Z",
            }])

            self.assertEqual(len(changes), 1)
            repaired = store.get_document_by_id(document_id)
            self.assertTrue(Path(wpm.writing_root_path, repaired["local_path"]).exists())
            self.assertEqual(
                wpm.read_text_file(repaired["local_path"]), "보존할 삭제 본문"
            )

    def test_equal_revision_remote_live_document_repairs_missing_local_copy(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "로컬 사본 복구 작품"
            wpm.writing_root_path = str(Path(temp_dir, "로컬 사본 복구 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/삭제실패복구.txt"
            document_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            store.apply_remote_snapshot(
                context, document_id, live_path, "서버에 남은 본문", 4
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_protected_paths_provider = lambda: set()

            changes = manager._apply_v2_remote_documents([{
                "document_id": document_id,
                "relative_path": live_path,
                "content": "서버에 남은 본문",
                "revision": 4,
                "is_deleted": False,
            }])

            self.assertEqual(len(changes), 1)
            self.assertEqual(wpm.read_text_file(live_path), "서버에 남은 본문")
            self.assertEqual(store.get_document_by_id(document_id)["revision"], 4)

    def test_empty_trash_records_synced_purge_and_frees_local_trash_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "휴지통 비우기 작품"
            wpm.writing_root_path = str(Path(temp_dir, "휴지통 비우기 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/영구삭제.txt"
            self.assertTrue(wpm.write_text_file(live_path, "삭제할 본문"))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)
            created = store.enqueue(manager._v2_context, live_path, "삭제할 본문")
            store.mark_success(created["operation_id"], {
                "revision": 1,
                "content_hash": "a" * 64,
            })
            with patch.object(manager, "retry_pending_syncs"):
                trash_path = wpm.move_to_trash(live_path)
                manager.record_tombstone(live_path, trash_path)
            deletion = store.next_ready_operation(manager._v2_context["local_key"])
            store.mark_success(deletion["operation_id"], {
                "revision": 2,
                "content_hash": "b" * 64,
            })
            trash_items = wpm.list_trash_items()
            wpm.empty_trash()

            with patch.object(manager, "retry_pending_syncs"):
                purge = manager.record_trash_purge(trash_items, empty_all=True)

            self.assertEqual(purge["relative_path"], TRASH_PURGE_DOCUMENT_PATH)
            self.assertEqual(wpm.list_trash_items(), [])
            document = store.get_document_by_id(created["document_id"])
            self.assertTrue(document["local_path"].startswith("__antigravity__/purged/"))
            self.assertEqual(
                wpm.project_settings["trash_purged_revisions"][created["document_id"]],
                2,
            )
            self.assertTrue(wpm.project_settings["trash_empty_generation"])

    def test_remote_empty_trash_marker_prevents_tombstone_rematerialization(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "원격 휴지통 비우기 작품"
            wpm.writing_root_path = str(Path(temp_dir, "원격 휴지통 비우기 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/다시생기면안됨.txt"
            document_id = str(uuid.uuid4())
            purge_document_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            trash_path = wpm.materialize_remote_tombstone(
                live_path, "삭제 본문", document_id=document_id
            )
            store.apply_remote_snapshot(
                context, document_id, live_path, "삭제 본문", 2,
                is_deleted=True, local_path=trash_path,
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_protected_paths_provider = lambda: set()
            purge_content = manager._trash_purge_content(
                {document_id: 2}, "empty-generation-1"
            )

            changes = manager._apply_v2_remote_documents([
                {
                    "document_id": document_id,
                    "relative_path": live_path,
                    "content": "삭제 본문",
                    "revision": 2,
                    "is_deleted": True,
                },
                {
                    "document_id": purge_document_id,
                    "relative_path": TRASH_PURGE_DOCUMENT_PATH,
                    "content": purge_content,
                    "revision": 1,
                    "is_deleted": False,
                },
            ])

            self.assertTrue(any(change["kind"] == "trash_purge" for change in changes))
            self.assertEqual(wpm.list_trash_items(), [])
            document = store.get_document_by_id(document_id)
            self.assertTrue(document["local_path"].startswith("__antigravity__/purged/"))

    def test_remote_tombstone_is_applied_before_immediate_path_reuse(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "이름 재사용 작품"
            wpm.writing_root_path = str(Path(temp_dir, "이름 재사용 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            reused_path = "메인/메모장/같은이름.txt"
            temporary_path = "메인/메모장/임시이름.txt"
            old_id = str(uuid.uuid4())
            new_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            store.apply_remote_snapshot(context, old_id, reused_path, "예전 문서", 1)
            store.apply_remote_snapshot(context, new_id, temporary_path, "새 문서", 1)
            self.assertTrue(wpm.write_text_file(reused_path, "예전 문서"))
            self.assertTrue(wpm.write_text_file(temporary_path, "새 문서"))
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_protected_paths_provider = lambda: set()

            changes = manager._apply_v2_remote_documents([
                {
                    "document_id": new_id,
                    "relative_path": reused_path,
                    "content": "새 문서",
                    "revision": 2,
                    "is_deleted": False,
                },
                {
                    "document_id": old_id,
                    "relative_path": reused_path,
                    "content": "예전 문서",
                    "revision": 2,
                    "is_deleted": True,
                },
            ])

            self.assertEqual(len(changes), 2)
            self.assertEqual(wpm.read_text_file(reused_path), "새 문서")
            self.assertFalse(Path(wpm.writing_root_path, temporary_path).exists())
            old_document = store.get_document_by_id(old_id)
            new_document = store.get_document_by_id(new_id)
            self.assertTrue(old_document["is_deleted"])
            self.assertTrue(old_document["local_path"].startswith("메인/휴지통/"))
            self.assertEqual(new_document["local_path"], reused_path)

    def test_late_editor_save_cannot_recreate_a_deleted_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "늦은 저장 차단 작품"
            wpm.writing_root_path = str(Path(temp_dir, "늦은 저장 차단 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            live_path = "메인/메모장/삭제완료.txt"
            self.assertTrue(wpm.write_text_file(live_path, "삭제 전"))
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, wpm.current_project, str(uuid.uuid4()), store=store)
            created = store.enqueue(manager._v2_context, live_path, "삭제 전")
            store.mark_success(created["operation_id"], {
                "revision": 1,
                "content_hash": "e" * 64,
            })
            with patch.object(manager, "retry_pending_syncs"):
                trash_path = wpm.move_to_trash(live_path)
                manager.record_tombstone(live_path, trash_path)
            deleted = store.next_ready_operation(manager._v2_context["local_key"])
            store.mark_success(deleted["operation_id"], {
                "revision": 2,
                "content_hash": "f" * 64,
            })
            callback = MagicMock()

            manager.upload_content_async(
                wpm,
                wpm.current_project,
                live_path,
                "편집기에 남은 늦은 한 글자",
                callback=callback,
            )

            self.assertFalse(Path(wpm.writing_root_path, live_path).exists())
            self.assertIsNone(store.get_document(manager._v2_context["local_key"], live_path))
            self.assertEqual(store.counts(manager._v2_context["local_key"])["total"], 0)
            callback.assert_called_once()

    def test_tombstone_received_before_live_file_vacates_reused_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "첫 수신이 삭제인 작품"
            wpm.writing_root_path = str(Path(temp_dir, "첫 수신이 삭제인 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            reused_path = "메인/메모장/재사용된이름.txt"
            old_id = str(uuid.uuid4())
            new_id = str(uuid.uuid4())
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, wpm.current_project, str(uuid.uuid4())
            )
            # Reproduce the old broken B state: tombstone metadata occupies the
            # live path even though B never downloaded the original file.
            store.apply_remote_snapshot(
                context,
                old_id,
                reused_path,
                "삭제된 예전 본문",
                2,
                is_deleted=True,
                local_path=reused_path,
            )
            manager = SyncManager()
            manager._v2_store = store
            manager._v2_context = context
            manager._v2_wpm = wpm
            manager._v2_device_id = str(uuid.uuid4())
            manager._v2_protected_paths_provider = lambda: set()

            changes = manager._apply_v2_remote_documents([
                {
                    "document_id": new_id,
                    "relative_path": reused_path,
                    "content": "이름을 재사용한 새 본문",
                    "revision": 5,
                    "is_deleted": False,
                },
                {
                    "document_id": old_id,
                    "relative_path": reused_path,
                    "content": "삭제된 예전 본문",
                    "revision": 2,
                    "is_deleted": True,
                },
            ])

            self.assertEqual(len(changes), 2)
            self.assertEqual(
                wpm.read_text_file(reused_path), "이름을 재사용한 새 본문"
            )
            old_document = store.get_document_by_id(old_id)
            new_document = store.get_document_by_id(new_id)
            self.assertTrue(old_document["local_path"].startswith("메인/휴지통/"))
            self.assertEqual(new_document["local_path"], reused_path)
            self.assertEqual(
                wpm.read_text_file(old_document["local_path"]), "삭제된 예전 본문"
            )
            trash_item = next(
                item for item in wpm.list_trash_items()
                if item["trash_path"] == old_document["local_path"]
            )
            self.assertEqual(trash_item["original_path"], reused_path)

    def test_v2_worker_does_not_override_native_qthread_finished_signal(self):
        self.assertIn("resultReady", V2QueueWorker.__dict__)
        self.assertNotIn("finished", V2QueueWorker.__dict__)

    def test_new_document_uses_commit_rpc_with_stable_ids(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "RPC 작품"
            wpm.writing_root_path = str(Path(temp_dir, "RPC 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, "RPC 작품", str(uuid.uuid4()), store=store)
            manager.supabase = _FakeClient()
            operation = store.enqueue(
                manager._v2_context, "메인/원고/001화.txt", "RPC 저장"
            )

            result = manager._process_v2_operation(operation["operation_id"])

            self.assertEqual(result["kind"], "committed")
            commit_name, params = manager.supabase.calls[-1]
            self.assertEqual(commit_name, "commit_document")
            self.assertEqual(params["p_document_id"], operation["document_id"])
            self.assertEqual(params["p_operation_id"], operation["operation_id"])
            self.assertEqual(params["p_base_revision"], 0)

    def test_remote_pull_renames_clean_file_but_skips_dirty_editor_path(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "수신 동기화 작품"
            wpm.writing_root_path = str(Path(temp_dir, "수신 동기화 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            context = store.configure_project(
                wpm.writing_root_path, "수신 동기화 작품", str(uuid.uuid4())
            )
            document_id = str(uuid.uuid4())
            old_path = "메인/메모장/예전이름.txt"
            new_path = "메인/메모장/새이름.txt"
            store.apply_remote_snapshot(
                context, document_id, old_path, "기준본", 1
            )
            self.assertTrue(wpm.write_text_file(old_path, "기준본"))

            manager = SyncManager()
            previous = (
                manager._v2_store,
                manager._v2_context,
                manager._v2_wpm,
                manager._v2_protected_paths_provider,
            )
            try:
                manager._v2_store = store
                manager._v2_context = context
                manager._v2_wpm = wpm
                manager._v2_device_id = str(uuid.uuid4())
                manager._v2_protected_paths_provider = lambda: set()
                changes = manager._apply_v2_remote_documents([{
                    "document_id": document_id,
                    "relative_path": new_path,
                    "content": "서버 최신본",
                    "revision": 2,
                    "is_deleted": False,
                }])

                self.assertEqual(len(changes), 1)
                self.assertEqual(wpm.read_text_file(old_path), "")
                self.assertEqual(wpm.read_text_file(new_path), "서버 최신본")
                self.assertEqual(store.get_document_by_id(document_id)["revision"], 2)

                manager._v2_protected_paths_provider = lambda: {new_path}
                skipped = manager._apply_v2_remote_documents([{
                    "document_id": document_id,
                    "relative_path": new_path,
                    "content": "편집 중에는 덮어쓰면 안 됨",
                    "revision": 3,
                    "is_deleted": False,
                }])

                self.assertEqual(skipped, [])
                self.assertEqual(wpm.read_text_file(new_path), "서버 최신본")
                self.assertEqual(store.get_document_by_id(document_id)["revision"], 2)

                manager._v2_protected_paths_provider = lambda: set()
                deleted = manager._apply_v2_remote_documents([{
                    "document_id": document_id,
                    "relative_path": new_path,
                    "content": "서버 최신본",
                    "revision": 3,
                    "is_deleted": True,
                    "deleted_at": "2026-07-14T08:12:13.456789Z",
                }])

                deleted_document = store.get_document_by_id(document_id)
                self.assertEqual(len(deleted), 1)
                self.assertTrue(deleted_document["is_deleted"])
                self.assertTrue(deleted_document["local_path"].startswith("메인/휴지통/"))
                self.assertEqual(wpm.read_text_file(new_path), "")
                self.assertEqual(
                    wpm.read_text_file(deleted_document["local_path"]), "서버 최신본"
                )
                trash_item = next(
                    item for item in wpm.list_trash_items()
                    if item["trash_path"] == deleted_document["local_path"]
                )
                self.assertEqual(
                    trash_item["deleted_at"], "2026-07-14T08:12:13.456789Z"
                )
                self.assertEqual(trash_item["document_id"], document_id)
            finally:
                (
                    manager._v2_store,
                    manager._v2_context,
                    manager._v2_wpm,
                    manager._v2_protected_paths_provider,
                ) = previous

    def test_forced_offline_mode_does_not_contact_lease_rpcs(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "오프라인 작품"
            wpm.writing_root_path = str(Path(temp_dir, "오프라인 작품", "집필모드"))
            Path(wpm.writing_root_path).mkdir(parents=True)
            store = SyncV2Store(str(Path(temp_dir, "sync.sqlite3")))
            manager = SyncManager()
            manager.configure_v2(wpm, "오프라인 작품", str(uuid.uuid4()), store=store)
            manager.supabase = _FakeClient()
            relative_path = "메인/원고/충돌테스트.txt"
            created = store.enqueue(manager._v2_context, relative_path, "기준본")
            store.mark_success(created["operation_id"], {
                "revision": 1,
                "content_hash": "c" * 64,
            })
            manager._v2_leases[created["document_id"]] = "lease-token"

            with patch("sync_manager.is_forced_offline", return_value=True):
                acquired, message = manager.check_and_acquire_lock(
                    "오프라인 작품", relative_path, "session-a"
                )
                manager.heartbeat_lock("오프라인 작품", relative_path, "session-a")
                released = manager.release_lock(
                    "오프라인 작품", relative_path, "session-a"
                )

            self.assertTrue(acquired)
            self.assertIn("오프라인", message)
            self.assertTrue(released)
            self.assertEqual(manager.supabase.calls, [])


class WritingManualSaveTestCase(unittest.TestCase):
    def test_scheduled_remote_refresh_does_not_clear_a_new_inline_editor(self):
        panel = WritingTreeMixin()
        panel.binder_tree = MagicMock()
        panel.load_tree_data = MagicMock()
        panel._remote_tree_refresh_pending = False
        panel._remote_tree_refresh_scheduled = False
        panel._tree_item_creation_active = False
        callbacks = []

        with patch(
            "writing_tree.QTimer.singleShot",
            side_effect=lambda _delay, callback: callbacks.append(callback),
        ):
            panel._schedule_remote_tree_refresh()
            panel._tree_item_creation_active = True
            callbacks[0]()

        panel.load_tree_data.assert_not_called()
        self.assertTrue(panel._remote_tree_refresh_pending)

        panel._tree_item_creation_active = False
        panel.binder_tree.state.return_value = 0
        panel._flush_remote_tree_refresh()

        panel.load_tree_data.assert_called_once_with()
        self.assertFalse(panel._remote_tree_refresh_pending)

    def test_rapid_creation_closes_and_queues_the_item_that_owned_the_editor(self):
        first_item = MagicMock()
        first_item.data.side_effect = lambda _column, role: {
            Qt.ItemDataRole.UserRole: "메인/메모장/새_문서.txt",
            Qt.ItemDataRole.UserRole + 1: False,
            Qt.ItemDataRole.UserRole + 4: True,
        }.get(role)
        last_item = MagicMock()
        panel = SimpleNamespace(
            _tree_creation_item=first_item,
            binder_tree=MagicMock(),
            sync_manager=MagicMock(),
            _finish_tree_item_creation=MagicMock(),
            save_tree_order=MagicMock(),
        )
        panel._commit_tree_item_creation = lambda item: (
            WritingTreeMixin._commit_tree_item_creation(panel, item)
        )
        panel.binder_tree.currentItem.return_value = last_item
        callbacks = []

        with patch(
            "writing_tree.QTimer.singleShot",
            side_effect=lambda _delay, callback: callbacks.append(callback),
        ):
            WritingTreeMixin.on_tree_editor_closed(panel)
            panel._tree_creation_item = last_item
            callbacks[0]()

        panel.sync_manager.record_path_change.assert_called_once_with(
            "메인/메모장/새_문서.txt", "메인/메모장/새_문서.txt"
        )
        panel._finish_tree_item_creation.assert_called_once_with(first_item)
        panel.save_tree_order.assert_called_once_with()

    def test_ctrl_s_queues_open_document_without_undefined_worker(self):
        editor = MagicMock()
        editor.toPlainText.return_value = "기준본"
        label = MagicMock()
        label.text.return_value = "충돌테스트.txt"
        panel = SimpleNamespace(
            current_loaded_file_left="메인/원고/충돌테스트.txt",
            current_loaded_file_right=None,
            left_editor=editor,
            is_dirty_left=True,
            is_dirty_right=False,
            wpm=MagicMock(),
            sync_manager=MagicMock(),
            pm=SimpleNamespace(current_project="V2 테스트"),
            on_sync_finished=MagicMock(),
            lbl_current_doc=label,
        )
        panel.wpm.write_text_file.return_value = True

        with patch("PyQt6.QtCore.QTimer.singleShot"):
            result = WritingModeWidget.manual_save(panel)

        self.assertIsNone(result)
        panel.wpm.write_text_file.assert_called_once_with(
            "메인/원고/충돌테스트.txt", "기준본"
        )
        panel.sync_manager.upload_content_async.assert_called_once()

    def test_ctrl_s_on_trash_copy_never_creates_cloud_document(self):
        editor = MagicMock()
        editor.toPlainText.return_value = "휴지통 보관본"
        panel = SimpleNamespace(
            current_loaded_file_left="메인/휴지통/삭제된문서.txt",
            current_loaded_file_right=None,
            left_editor=editor,
            is_dirty_left=False,
            is_dirty_right=False,
            wpm=MagicMock(),
            sync_manager=MagicMock(),
            pm=SimpleNamespace(current_project="V2 테스트"),
            on_sync_finished=MagicMock(),
            lbl_current_doc=MagicMock(),
        )

        WritingModeWidget.manual_save(panel)

        panel.wpm.write_text_file.assert_not_called()
        panel.sync_manager.upload_content_async.assert_not_called()

    def test_temporary_new_item_is_not_opened_before_name_is_confirmed(self):
        item = MagicMock()
        item.data.side_effect = lambda _column, role: (
            True if role == Qt.ItemDataRole.UserRole + 4 else "메인/메모장/새_문서.txt"
        )
        panel = SimpleNamespace(_open_file_by_path=MagicMock())

        WritingTreeMixin.on_tree_current_item_changed(panel, item, None)

        panel._open_file_by_path.assert_not_called()


if __name__ == "__main__":
    unittest.main(verbosity=2)
