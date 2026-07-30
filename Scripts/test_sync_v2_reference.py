#!/usr/bin/env python3

import sys
import tempfile
import unittest
import uuid
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPOSITORY_ROOT / "참조파일"))

from sync_v2_store import SyncV2Store  # noqa: E402
from three_way_merge import three_way_merge  # noqa: E402


class SyncV2ReferenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        root = Path(self.temporary_directory.name)
        self.database_path = root / "sync-v2.sqlite3"
        self.store = SyncV2Store(str(self.database_path))
        self.context = self.store.configure_project(
            str(root / "집필모드"), "계약 감사", str(uuid.uuid4())
        )

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_queue_survives_restart_with_the_same_operation_id(self):
        operation = self.store.enqueue(
            self.context, "메인/원고/001화.txt", "종료 전 본문"
        )
        reopened = SyncV2Store(str(self.database_path))

        recovered = reopened.next_ready_operation(self.context["local_key"])

        self.assertEqual(recovered["operation_id"], operation["operation_id"])
        self.assertEqual(recovered["content"], "종료 전 본문")

    def test_inflight_operation_returns_to_pending_after_restart(self):
        operation = self.store.enqueue(
            self.context, "메인/원고/002화.txt", "전송 중 본문"
        )
        self.store.mark_attempt(operation["operation_id"])

        reopened = SyncV2Store(str(self.database_path))
        recovered = reopened.next_ready_operation(self.context["local_key"])

        self.assertEqual(recovered["operation_id"], operation["operation_id"])
        self.assertEqual(recovered["status"], "pending")

    def test_success_promotes_the_next_operation_to_the_returned_revision(self):
        first = self.store.enqueue(
            self.context, "메인/원고/003화.txt", "첫 저장"
        )
        second = self.store.enqueue(
            self.context, "메인/원고/003화.txt", "두 번째 저장"
        )

        self.store.mark_success(
            first["operation_id"],
            {"revision": 7, "content_hash": "a" * 64},
        )

        promoted = self.store.operation(second["operation_id"])
        self.assertEqual(promoted["base_revision"], 7)
        self.assertEqual(promoted["base_content"], "첫 저장")

    def test_non_overlapping_edits_merge_without_markers(self):
        result = three_way_merge(
            "첫 줄\n둘째 줄\n셋째 줄\n",
            "첫 줄 수정\n둘째 줄\n셋째 줄\n",
            "첫 줄\n둘째 줄\n셋째 줄 수정\n",
        )

        self.assertFalse(result.has_conflicts)
        self.assertEqual(result.content, "첫 줄 수정\n둘째 줄\n셋째 줄 수정\n")

    def test_overlapping_edits_preserve_base_local_and_remote(self):
        result = three_way_merge("공통\n", "로컬\n", "원격\n")

        self.assertTrue(result.has_conflicts)
        self.assertEqual(result.conflict_count, 1)
        self.assertIn("바꾸기 전 원본", result.content)
        self.assertIn("로컬 편집본", result.content)
        self.assertIn("서버 최신본", result.content)
        difference = result.content.split("로컬과 서버 차이점\n\n", 1)[1]
        self.assertIn("로컬 : 로컬", difference)
        self.assertIn("서버 : 원격", difference)
        self.assertTrue(
            result.content.startswith("=========\n\n바꾸기 전 원본")
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
