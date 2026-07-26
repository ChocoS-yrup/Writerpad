import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from mode_writing import WritingModeWidget
from project_manager_writing import WritingProjectManager
from settings_panel import SettingsPanel
from sync_manager import SaveWorker, SyncManager


class SyncManagerStateTestCase(unittest.TestCase):
    def setUp(self):
        self.manager = SyncManager()
        self.previous_v2_state = (
            self.manager._v2_store,
            self.manager._v2_context,
            self.manager._v2_wpm,
            dict(self.manager._v2_leases),
        )
        self.manager._v2_store = None
        self.manager._v2_context = None
        self.manager._v2_wpm = None
        self.manager._v2_leases = {}
        self.manager._retry_queue = {}
        self.manager._retry_active_key = None
        self.manager._active_server_syncs = 0
        self.manager._active_backups = 0
        self.manager._last_sync_error = ""
        self.manager._last_failure_offline = False
        self.states = []
        self.manager.syncStateChanged.connect(self._record_state)

    def tearDown(self):
        self.manager.syncStateChanged.disconnect(self._record_state)
        self.manager._retry_queue = {}
        self.manager._retry_active_key = None
        self.manager._active_server_syncs = 0
        self.manager._active_backups = 0
        (
            self.manager._v2_store,
            self.manager._v2_context,
            self.manager._v2_wpm,
            previous_leases,
        ) = self.previous_v2_state
        self.manager._v2_leases = previous_leases

    def _record_state(self, state, detail, pending_count):
        self.states.append((state, detail, pending_count))

    def test_state_priority_covers_backup_sync_offline_failure_and_saved(self):
        self.manager._active_backups = 1
        self.manager._publish_sync_state()
        self.assertEqual(self.states[-1][0], "backup")

        self.manager._active_server_syncs = 1
        self.manager._publish_sync_state()
        self.assertEqual(self.states[-1][0], "syncing")

        self.manager._active_server_syncs = 0
        self.manager._active_backups = 0
        retry_key = ("content", "작품", "001화.txt")
        self.manager._queue_retry(retry_key, {"kind": "content"}, "connection timeout", offline=True)
        self.manager._publish_sync_state()
        self.assertEqual(self.states[-1][0], "offline")

        self.manager._retry_queue[retry_key]["_retry_offline"] = False
        self.manager._publish_sync_state()
        self.assertEqual(self.states[-1][0], "failed")

        self.manager._retry_queue.clear()
        self.manager._publish_sync_state()
        self.assertEqual(self.states[-1][0], "saved")

    def test_retry_queue_keeps_only_the_latest_content_for_each_file(self):
        key = ("content", "작품", "메인/원고/1권/001화.txt")
        self.manager._queue_retry(key, {"kind": "content", "content": "이전 내용"}, "timeout", offline=True)
        self.manager._queue_retry(key, {"kind": "content", "content": "최신 내용"}, "timeout", offline=True)

        self.assertEqual(self.manager.pending_retry_count, 1)
        self.assertEqual(self.manager._retry_queue[key]["content"], "최신 내용")

    def test_persistent_lease_conflict_has_a_distinct_user_state(self):
        old_store = self.manager._v2_store
        old_context = self.manager._v2_context
        old_device = self.manager._v2_device_id
        try:
            self.manager._v2_store = SimpleNamespace(
                counts=lambda _key: {
                    "pending": 1, "inflight": 0, "conflict": 0, "total": 1
                },
                latest_error=lambda _key: "LEASE_CONFLICT",
            )
            self.manager._v2_context = {"local_key": "B"}
            self.manager._v2_device_id = "device-b"

            self.manager._publish_sync_state()

            self.assertEqual(self.states[-1][0], "lease")
            self.assertIn("다른 기기", self.states[-1][1])
        finally:
            self.manager._v2_store = old_store
            self.manager._v2_context = old_context
            self.manager._v2_device_id = old_device

    def test_retry_dispatches_one_queued_item_at_a_time(self):
        key = ("content", "작품", "001화.txt")
        payload = {"kind": "content", "content": "재시도 내용"}
        self.manager._retry_queue[key] = payload

        with patch.object(self.manager, "_launch_content_upload") as launch:
            self.assertTrue(self.manager.retry_pending_syncs())

        launch.assert_called_once_with(payload, key, is_retry=True)
        self.assertEqual(self.manager._retry_active_key, key)
        self.assertFalse(self.manager.retry_pending_syncs())

    def test_failed_attempt_is_queued_and_later_success_removes_it(self):
        key = ("content", "작품", "001화.txt")
        payload = {"kind": "content", "content": "보존할 내용"}

        self.manager._active_server_syncs = 1
        success, _ = self.manager._complete_server_attempt(
            key, payload, False, "connection timeout", SimpleNamespace(supabase=None), is_retry=False
        )
        self.assertFalse(success)
        self.assertIn(key, self.manager._retry_queue)
        self.assertEqual(self.manager.current_sync_state, "offline")

        self.manager._active_server_syncs = 1
        success, _ = self.manager._complete_server_attempt(
            key, payload, True, "", SimpleNamespace(supabase=object()), is_retry=False
        )
        self.assertTrue(success)
        self.assertNotIn(key, self.manager._retry_queue)
        self.assertEqual(self.manager.current_sync_state, "saved")

    def test_offline_save_worker_still_saves_locally_and_reports_server_failure(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            wpm = WritingProjectManager()
            wpm.workspace_dir = temp_dir
            wpm.current_project = "테스트 작품"
            wpm.writing_root_path = str(Path(temp_dir, "테스트 작품", "집필모드"))
            relative_path = "메인/원고/1권/001화.txt"
            result = []

            worker = SaveWorker(None, wpm, "테스트 작품", relative_path, "로컬에는 반드시 남을 내용")
            worker.finished.connect(lambda *args: result.append(args))
            with patch.object(SyncManager, "create_supabase_client", return_value=None):
                worker.run()

            self.assertEqual(wpm.read_text_file(relative_path), "로컬에는 반드시 남을 내용")
            self.assertEqual(result[0][0], False)
            self.assertIn("서버 연결 없음", result[0][1])

    def test_failed_session_restore_is_not_reported_as_logged_in(self):
        stale_session = SimpleNamespace(
            user=SimpleNamespace(email="stale@example.com")
        )
        target = SimpleNamespace(
            supabase=SimpleNamespace(
                _antigravity_authenticated=False,
                auth=SimpleNamespace(get_session=lambda: stale_session),
            )
        )

        self.assertEqual(SyncManager.authenticated_email(target), "")

    def test_frozen_build_reads_bundled_supabase_configuration(self):
        import sync_manager

        with patch.object(sync_manager.sys, "_MEIPASS", "C:/bundle", create=True):
            self.assertEqual(sync_manager.supabase_config_dir(), "C:/bundle")

    def test_windows_build_includes_public_supabase_configuration(self):
        spec = Path("Antigravity_AI_Writer.spec").read_text(encoding="utf-8")

        self.assertIn("('.env', '.')", spec)


class _FakeLabel:
    def __init__(self):
        self.text = ""
        self.style = ""
        self.tooltip = ""

    def setText(self, value):
        self.text = value

    def setStyleSheet(self, value):
        self.style = value

    def setToolTip(self, value):
        self.tooltip = value


class StorageStatusLabelTestCase(unittest.TestCase):
    def test_all_user_visible_status_labels(self):
        target = SimpleNamespace(lbl_storage_status=_FakeLabel())
        expected = {
            "saved": "저장됨",
            "backup": "자동백업 중",
            "syncing": "서버 동기화 중",
            "offline": "오프라인 임시 저장됨",
            "lease": "다른 기기 편집 중",
            "failed": "동기화 실패 — 재시도 필요",
        }

        for state, label in expected.items():
            WritingModeWidget.update_storage_status(
                target, state, "상세 상태", 1 if state in {"offline", "lease", "failed"} else 0
            )
            self.assertIn(label, target.lbl_storage_status.text)

        self.assertIn("클릭하면 지금 재시도", target.lbl_storage_status.tooltip)

    def test_storage_status_makes_restored_cloud_login_visible(self):
        target = SimpleNamespace(
            lbl_storage_status=_FakeLabel(),
            sync_manager=SimpleNamespace(
                authenticated_email=lambda: "writer@example.com"
            ),
        )

        WritingModeWidget.update_storage_status(target, "saved", "", 0)

        self.assertIn("클라우드 로그인됨", target.lbl_storage_status.text)
        self.assertIn("writer@example.com", target.lbl_storage_status.tooltip)

    def test_settings_panel_labels_automatic_login_without_showing_password(self):
        target = SimpleNamespace(
            lbl_supabase_status=_FakeLabel(),
            btn_supabase_login=_FakeLabel(),
        )

        SettingsPanel.refresh_supabase_account_status(target, "writer@example.com")

        self.assertIn("자동 로그인됨: writer@example.com", target.lbl_supabase_status.text)
        self.assertIn("비밀번호는 저장하지 않고", target.lbl_supabase_status.text)
        self.assertEqual(target.btn_supabase_login.text, "계정 변경")

    def test_compact_status_button_retries_only_when_items_are_pending(self):
        calls = []
        target = SimpleNamespace(
            _storage_pending_count=0,
            sync_manager=SimpleNamespace(retry_pending_syncs=lambda: calls.append("retry")),
        )

        WritingModeWidget._retry_storage_sync(target)
        self.assertEqual(calls, [])

        target._storage_pending_count = 2
        WritingModeWidget._retry_storage_sync(target)
        self.assertEqual(calls, ["retry"])

    def test_conflict_status_retries_independent_queue_before_opening_folder(self):
        retry = MagicMock(return_value=True)
        target = SimpleNamespace(
            _storage_state="conflict",
            _storage_pending_count=3,
            sync_manager=SimpleNamespace(retry_pending_syncs=retry),
            open_conflict_folder=MagicMock(),
        )

        WritingModeWidget._retry_storage_sync(target)

        retry.assert_called_once_with()
        target.open_conflict_folder.assert_not_called()

        retry.reset_mock()
        retry.return_value = False
        WritingModeWidget._retry_storage_sync(target)

        retry.assert_called_once_with()
        target.open_conflict_folder.assert_called_once_with()

    def test_successful_conflict_resolution_restores_document_label(self):
        target = SimpleNamespace(
            loaded_versions={},
            current_loaded_file_left="메인/메모장/해결본.txt",
            current_loaded_file_right=None,
            lbl_current_doc=_FakeLabel(),
            lbl_r_doc=_FakeLabel(),
        )
        target.lbl_current_doc.text = "해결본.txt (충돌 해결 필요)"

        WritingModeWidget.on_sync_finished(
            target, True, "", "메인/메모장/해결본.txt", 5
        )

        self.assertEqual(target.lbl_current_doc.text, "해결본.txt")
        self.assertEqual(
            target.loaded_versions["메인/메모장/해결본.txt"], 5
        )

    def test_remote_refresh_updates_clean_open_editor_and_renamed_path(self):
        editor = MagicMock()
        target = SimpleNamespace(
            controller=MagicMock(),
            loaded_versions={"메인/메모장/예전.txt": 1},
            current_loaded_file_left="메인/메모장/예전.txt",
            current_loaded_file_right=None,
            left_editor=editor,
            right_editor=MagicMock(),
            lbl_current_doc=_FakeLabel(),
            lbl_r_doc=_FakeLabel(),
            is_dirty_left=False,
            is_dirty_right=False,
            load_tree_data=MagicMock(),
            _schedule_remote_tree_refresh=MagicMock(),
        )

        WritingModeWidget.on_remote_documents_applied(target, [{
            "old_local_path": "메인/메모장/예전.txt",
            "new_local_path": "메인/메모장/새이름.txt",
            "content": "다른 Windows에서 저장한 내용",
            "revision": 7,
            "is_deleted": False,
        }])

        self.assertEqual(target.current_loaded_file_left, "메인/메모장/새이름.txt")
        editor.setPlainText.assert_called_once_with("다른 Windows에서 저장한 내용")
        self.assertEqual(target.lbl_current_doc.text, "새이름.txt")
        self.assertEqual(target.loaded_versions["메인/메모장/새이름.txt"], 7)
        target.controller.rename_path.assert_called_once()
        target._schedule_remote_tree_refresh.assert_called_once()
        target.load_tree_data.assert_not_called()

    def test_dirty_open_editor_is_reported_as_remote_pull_protected(self):
        left_editor = MagicMock()
        left_editor.document.return_value.isModified.return_value = False
        right_editor = MagicMock()
        right_editor.document.return_value.isModified.return_value = True
        target = SimpleNamespace(
            current_loaded_file_left="메인/메모장/왼쪽.txt",
            current_loaded_file_right="메인/메모장/오른쪽.txt",
            is_dirty_left=True,
            is_dirty_right=False,
            left_editor=left_editor,
            right_editor=right_editor,
        )

        protected = WritingModeWidget.get_remote_sync_protected_paths(target)

        self.assertEqual(protected, {
            "메인/메모장/왼쪽.txt",
            "메인/메모장/오른쪽.txt",
        })


if __name__ == "__main__":
    unittest.main(verbosity=2)
