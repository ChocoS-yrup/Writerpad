import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, call

from PyQt6.QtCore import QMutex

from mode_writing import WritingModeWidget
from project_manager import ProjectManager
from project_manager_writing import WritingProjectManager
from sync_manager import AutoSaveWorker
from writing_tree import WritingTreeMixin


class WritingDataTestCase(unittest.TestCase):
    """실제 작품 폴더 대신 매 테스트마다 임시 작업공간만 사용한다."""

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.project_name = "테스트 작품"

        self.wpm = WritingProjectManager()
        self.wpm.workspace_dir = str(self.root)
        self.wpm.current_project = self.project_name
        self.wpm.writing_root_path = str(self.root / self.project_name / "집필모드")
        self.wpm.settings_path = str(Path(self.wpm.writing_root_path) / "설정.json")
        self.wpm.project_settings = {}
        self.wpm._create_folder_structure()

    def tearDown(self):
        self.temp_dir.cleanup()

    def path(self, relative_path):
        return Path(self.wpm.writing_root_path, relative_path)

    def test_atomic_file_save_and_rename_and_move_preserve_content(self):
        original = "메인/메모/초안.txt"
        renamed = "메인/메모/수정 초안.txt"
        destination = "메인/복선"
        content = "원고 내용은 파일 이름이나 위치를 바꿔도 보존되어야 합니다."

        self.assertTrue(self.wpm.write_text_file(original, content))
        self.assertEqual(self.wpm.read_text_file(original), content)
        self.assertFalse(self.path(original + ".tmp").exists())

        self.assertTrue(self.wpm.rename_item(original, renamed))
        self.assertFalse(self.path(original).exists())
        self.assertEqual(self.wpm.read_text_file(renamed), content)

        moved = self.wpm.move_item(renamed, destination)
        self.assertEqual(moved, "메인/복선/수정 초안.txt")
        self.assertEqual(self.wpm.read_text_file(moved), content)

    def test_creating_same_name_adds_a_suffix_without_overwriting(self):
        parent = "메인/메모"
        self.path(parent).mkdir(parents=True, exist_ok=True)

        first = self.wpm.create_physical_item(parent, "아이디어", is_folder=False)
        self.assertEqual(first, "아이디어.txt")
        self.assertTrue(self.wpm.write_text_file(f"{parent}/{first}", "첫 번째"))

        second = self.wpm.create_physical_item(parent, "아이디어", is_folder=False)
        self.assertEqual(second, "아이디어 (1).txt")
        self.assertEqual(self.wpm.read_text_file(f"{parent}/{first}"), "첫 번째")
        self.assertEqual(self.wpm.read_text_file(f"{parent}/{second}"), "")

    def test_trash_keeps_duplicate_files_then_empty_trash_removes_them(self):
        source = "메인/메모/삭제 대상.txt"
        self.assertTrue(self.wpm.write_text_file(source, "첫 번째 원고"))
        self.assertTrue(self.wpm.move_to_trash(source))

        self.assertTrue(self.wpm.write_text_file(source, "두 번째 원고"))
        self.assertTrue(self.wpm.move_to_trash(source))

        trash_dir = self.path("메인/휴지통")
        trashed_files = sorted(path for path in trash_dir.iterdir() if path.is_file())
        self.assertEqual(len(trashed_files), 2)
        self.assertEqual(sorted(path.read_text(encoding="utf-8") for path in trashed_files), ["두 번째 원고", "첫 번째 원고"])

        self.assertTrue(self.wpm.empty_trash())
        self.assertEqual(list(trash_dir.iterdir()), [])

    def test_trash_tree_uses_latest_deletion_order_on_every_device(self):
        first_name = "먼저삭제.txt"
        latest_name = "나중삭제.txt"
        trash_dir = self.path("메인/휴지통")
        (trash_dir / first_name).write_text("첫 번째", encoding="utf-8")
        (trash_dir / latest_name).write_text("두 번째", encoding="utf-8")
        self.wpm._save_trash_index({
            first_name: {
                "original_path": f"메인/메모장/{first_name}",
                "deleted_at": "2026-07-14T16:10:00",
            },
            latest_name: {
                "original_path": f"메인/메모장/{latest_name}",
                "deleted_at": "2026-07-14T16:20:00",
            },
        })
        self.wpm.project_settings["tree_order"] = {
            "메인/휴지통": [first_name, latest_name]
        }
        panel = WritingTreeMixin()
        panel.wpm = self.wpm

        entries = panel._sorted_tree_entries(str(trash_dir), "메인/휴지통")

        self.assertEqual(entries, [latest_name, first_name])

    def test_trash_tree_uses_document_uuid_when_server_times_match(self):
        first_name = "장치마다이름이다른A.txt"
        second_name = "장치마다이름이다른B.txt"
        trash_dir = self.path("메인/휴지통")
        (trash_dir / first_name).write_text("A", encoding="utf-8")
        (trash_dir / second_name).write_text("B", encoding="utf-8")
        self.wpm._save_trash_index({
            first_name: {
                "original_path": "메인/메모장/A.txt",
                "deleted_at": "2026-07-14T16:20:00.000000Z",
                "document_id": "00000000-0000-0000-0000-000000000002",
            },
            second_name: {
                "original_path": "메인/메모장/B.txt",
                "deleted_at": "2026-07-14T16:20:00.000000Z",
                "document_id": "00000000-0000-0000-0000-000000000001",
            },
        })
        panel = WritingTreeMixin()
        panel.wpm = self.wpm

        entries = panel._sorted_tree_entries(str(trash_dir), "메인/휴지통")

        self.assertEqual(entries, [second_name, first_name])

    def test_server_metadata_replaces_local_trash_order_metadata(self):
        original = "메인/메모장/서버순서.txt"
        self.assertTrue(self.wpm.write_text_file(original, "내용"))
        trash_path = self.wpm.move_to_trash(original)
        committed_at = "2026-07-14T08:12:13.456789Z"
        document_id = "00000000-0000-0000-0000-000000000123"

        self.assertTrue(
            self.wpm.update_trash_metadata(trash_path, committed_at, document_id)
        )

        item = self.wpm.list_trash_items()[0]
        self.assertEqual(item["deleted_at"], committed_at)
        self.assertEqual(item["document_id"], document_id)

    def test_tree_population_blocks_item_change_signals_and_restores_state(self):
        panel = WritingTreeMixin()
        panel.binder_tree = MagicMock()
        panel.binder_tree.blockSignals.return_value = False
        panel.wpm = self.wpm
        parent = MagicMock()
        empty_dir = self.path("메인/메모장")

        panel._populate_tree_level(parent, str(empty_dir), "메인/메모장")

        self.assertEqual(
            panel.binder_tree.blockSignals.call_args_list,
            [call(True), call(False)],
        )
        parent.takeChildren.assert_called_once_with()

    def test_document_cannot_be_used_as_new_item_parent(self):
        panel = WritingTreeMixin()
        panel.wpm = MagicMock()
        parent = MagicMock()
        parent.data.return_value = False

        panel.start_create_item(parent, is_folder=False)

        panel.wpm.create_physical_item.assert_not_called()

    def test_delete_cleanup_resets_open_editors_without_old_label_attribute(self):
        deleted_folder = "메인/메모장/삭제 대상"
        parent_item = MagicMock()
        item = MagicMock()
        item.parent.return_value = parent_item
        left_editor = MagicMock()
        right_editor = MagicMock()
        panel = SimpleNamespace(
            binder_tree=MagicMock(),
            current_loaded_file_left=f"{deleted_folder}/왼쪽.txt",
            current_loaded_file_right=f"{deleted_folder}/오른쪽.txt",
            left_editor=left_editor,
            right_editor=right_editor,
            lbl_current_doc=MagicMock(),
            lbl_r_doc=MagicMock(),
            is_dirty_left=True,
            is_dirty_right=True,
            save_tree_order=MagicMock(),
        )

        WritingTreeMixin._cleanup_after_delete(panel, deleted_folder, item)

        parent_item.removeChild.assert_called_once_with(item)
        self.assertIsNone(panel.current_loaded_file_left)
        self.assertIsNone(panel.current_loaded_file_right)
        panel.lbl_current_doc.setText.assert_called_once_with("문서를 선택하세요")
        panel.lbl_r_doc.setText.assert_called_once_with("문서를 선택하세요")
        left_editor.setReadOnly.assert_called_once_with(True)
        right_editor.setReadOnly.assert_called_once_with(True)
        self.assertFalse(panel.is_dirty_left)
        self.assertFalse(panel.is_dirty_right)
        panel.save_tree_order.assert_called_once_with()

    def test_volumes_create_exactly_twenty_five_sequential_chapters(self):
        first_volume = self.wpm.add_volume()
        second_volume = self.wpm.add_volume()

        manuscript = self.path("메인/원고")
        first_chapters = sorted(path.name for path in (manuscript / first_volume).glob("*.txt"))
        second_chapters = sorted(path.name for path in (manuscript / second_volume).glob("*.txt"))

        self.assertEqual((first_volume, second_volume), ("1권", "2권"))
        self.assertEqual(len(first_chapters), 25)
        self.assertEqual(len(second_chapters), 25)
        self.assertEqual(first_chapters[0], "001화.txt")
        self.assertEqual(first_chapters[-1], "025화.txt")
        self.assertEqual(second_chapters[0], "026화.txt")
        self.assertEqual(second_chapters[-1], "050화.txt")

    def test_autosave_writes_only_a_timestamped_backup_copy(self):
        relative_path = "메인/원고/1권/001화.txt"
        content = "자동저장은 현재 원고를 덮어쓰지 않고 백업본을 남깁니다."

        worker = AutoSaveWorker(self.wpm, relative_path, content)
        worker.run()

        backup_dir = self.path("백업/자동저장/001화")
        backups = list(backup_dir.glob("001화_*.txt"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(encoding="utf-8"), content)
        self.assertFalse(self.path(relative_path).exists())

    def test_backup_history_supports_minute_and_second_timestamps_and_diff(self):
        relative_path = "메인/원고/1권/001화.txt"
        self.assertTrue(self.wpm.write_text_file(relative_path, "첫 줄\n현재 줄"))
        backup_dir = self.path("백업/자동저장/001화")
        backup_dir.mkdir(parents=True, exist_ok=True)
        older = backup_dir / "001화_20260713_1200.txt"
        newer = backup_dir / "001화_20260713_120030.txt"
        older.write_text("첫 줄\n오래된 줄", encoding="utf-8")
        newer.write_text("첫 줄\n복원할 줄\n추가 줄", encoding="utf-8")

        history = self.wpm.list_backup_history(relative_path)

        self.assertEqual([Path(item["path"]).name for item in history], [newer.name, older.name])
        comparison = self.wpm.compare_with_backup(relative_path, history[0]["path"])
        self.assertEqual(comparison["backup_content"], "첫 줄\n복원할 줄\n추가 줄")
        self.assertEqual((comparison["additions"], comparison["deletions"]), (2, 1))
        self.assertIn("-현재 줄", comparison["diff"])
        self.assertIn("+복원할 줄", comparison["diff"])

    def test_restore_backup_preserves_current_version_before_replacing_it(self):
        relative_path = "메인/원고/1권/002화.txt"
        current_content = "복원 직전 현재 원고"
        restored_content = "선택한 자동저장 원고"
        self.assertTrue(self.wpm.write_text_file(relative_path, current_content))
        backup_path = self.path("백업/자동저장/002화/002화_20260713_1210.txt")
        backup_path.parent.mkdir(parents=True, exist_ok=True)
        backup_path.write_text(restored_content, encoding="utf-8")

        result = self.wpm.restore_backup(relative_path, str(backup_path))

        self.assertEqual(self.wpm.read_text_file(relative_path), restored_content)
        self.assertIsNotNone(result["pre_restore_path"])
        self.assertEqual(Path(result["pre_restore_path"]).read_text(encoding="utf-8"), current_content)
        self.assertIn(str(self.path("백업/복원전/002화")), result["pre_restore_path"])

    def test_trash_restores_to_original_or_selected_location_without_overwriting(self):
        original = "메인/메모장/되살릴 글.txt"
        self.assertTrue(self.wpm.write_text_file(original, "원래 내용"))
        self.assertTrue(self.wpm.move_to_trash(original))
        trashed = self.wpm.list_trash_items()[0]
        self.assertEqual(trashed["original_path"], original)

        restored = self.wpm.restore_from_trash(trashed["trash_path"])
        self.assertEqual(restored, original)
        self.assertEqual(self.wpm.read_text_file(original), "원래 내용")

        self.assertTrue(self.wpm.move_to_trash(original))
        trashed = self.wpm.list_trash_items()[0]
        selected_parent = "메인/설정집/복구함"
        selected = self.wpm.restore_from_trash(trashed["trash_path"], selected_parent)
        self.assertEqual(selected, f"{selected_parent}/되살릴 글.txt")
        self.assertEqual(self.wpm.read_text_file(selected), "원래 내용")

        self.assertTrue(self.wpm.write_text_file(original, "기존 파일"))
        self.assertTrue(self.wpm.write_text_file("메인/메모장/충돌.txt", "휴지통 파일"))
        self.assertTrue(self.wpm.move_to_trash("메인/메모장/충돌.txt"))
        collision_item = next(item for item in self.wpm.list_trash_items() if item["original_path"].endswith("충돌.txt"))
        self.assertTrue(self.wpm.write_text_file("메인/메모장/충돌.txt", "새 현재본"))
        with self.assertRaises(FileExistsError):
            self.wpm.restore_from_trash(collision_item["trash_path"])
        self.assertEqual(self.wpm.read_text_file("메인/메모장/충돌.txt"), "새 현재본")

    def test_full_and_partial_extraction_keep_sources_unchanged(self):
        volume = self.path("메인/원고/1권")
        volume.mkdir(parents=True, exist_ok=True)
        long_one = "가" * 350
        long_two = "나" * 350
        short_three = "다" * 20
        long_four = "라" * 350
        source_texts = {
            "001화.txt": long_one,
            "002화.txt": long_two,
            "003화.txt": short_three,
            "004화.txt": long_four,
        }
        for filename, content in source_texts.items():
            (volume / filename).write_text(content, encoding="utf-8")

        # UI를 만들지 않고, 파일 탐색·조합 로직만 호출한다.
        extractor = WritingModeWidget.__new__(WritingModeWidget)
        extractor.wpm = SimpleNamespace(writing_root_path=self.wpm.writing_root_path)
        chapters = extractor._get_all_chapter_files()

        full_text, _, full_included = extractor._extract_chapters_to_file(chapters, check_length=True)
        partial = [chapter for chapter in chapters if 2 <= chapter[0] <= 4]
        partial_text, _, partial_included = extractor._extract_chapters_to_file(partial, check_length=False)

        self.assertEqual(full_included, [1, 2])
        self.assertIn(long_one, full_text)
        self.assertIn(long_two, full_text)
        self.assertNotIn(short_three, full_text)
        self.assertNotIn(long_four, full_text)

        self.assertEqual(partial_included, [2, 3, 4])
        self.assertIn(long_two, partial_text)
        self.assertIn(short_three, partial_text)
        self.assertIn(long_four, partial_text)
        self.assertEqual(
            {path.name: path.read_text(encoding="utf-8") for path in volume.glob("*.txt")},
            source_texts,
        )


class AssistantProjectStorageTestCase(unittest.TestCase):
    """AI 보조 모드의 원고/백업 저장도 임시 폴더에서 확인한다."""

    def test_chapter_and_backup_save_do_not_share_the_same_file(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            manager = ProjectManager.__new__(ProjectManager)
            manager.mutex = QMutex()
            manager.workspace_dir = temp_dir
            manager.config_path = os.path.join(temp_dir, "config.json")
            manager.global_config = {"last_project": ""}
            manager.current_project = None
            manager.project_path = None
            manager.project_settings_path = None
            manager.session_cost = 0.0
            manager.set_current_project("테스트 작품")

            manager.save_chapter_text("완성본", 7, "현재 원고")
            manager.save_chapter_text(
                "완성본", 7, "자동저장 원고", is_backup=True, backup_type="자동저장", timestamp="20260713_1200"
            )

            self.assertEqual(manager.load_chapter_text("완성본", 7), "현재 원고")
            backup_path = manager.get_text_file_path(
                "완성본", 7, is_backup=True, backup_type="자동저장", timestamp="20260713_1200"
            )
            self.assertEqual(Path(backup_path).read_text(encoding="utf-8"), "자동저장 원고")


if __name__ == "__main__":
    unittest.main(verbosity=2)
