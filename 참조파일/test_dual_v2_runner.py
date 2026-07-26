import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from windows_v2_dual_test import (
    RENAME_TEST_CONTENT,
    RENAME_TEST_RELATIVE_PATH,
    _make_profile,
    _seed_rename_document,
    set_offline,
)


class DualV2RunnerTestCase(unittest.TestCase):
    def test_online_command_uses_cp949_safe_output(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            profile_dir = Path(temp_dir, "A")
            profile_dir.mkdir()
            marker = profile_dir / "OFFLINE"
            marker.write_text("offline", encoding="ascii")
            manifest = {"run_dir": temp_dir}
            output = io.StringIO()

            with patch("windows_v2_dual_test._read_manifest", return_value=manifest):
                with redirect_stdout(output):
                    set_offline(SimpleNamespace(target="A"), False)

            rendered = output.getvalue()
            rendered.encode("cp949")
            self.assertFalse(marker.exists())
            self.assertIn("온라인 복구됨 -", rendered)

    def test_profile_includes_renameable_shared_memo_document(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            profile_dir = _make_profile(Path(temp_dir), "A", "테스트 작품")
            target = (
                profile_dir
                / "root"
                / "작품목록"
                / "테스트 작품"
                / "집필모드"
                / RENAME_TEST_RELATIVE_PATH
            )

            self.assertEqual(target.read_text(encoding="utf-8"), RENAME_TEST_CONTENT)

    def test_prepare_does_not_overwrite_an_existing_document(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            profile_dir = Path(temp_dir, "A")
            target, created = _seed_rename_document(profile_dir, "테스트 작품")
            self.assertTrue(created)
            target.write_text("사용자 수정본", encoding="utf-8")

            same_target, created_again = _seed_rename_document(
                profile_dir, "테스트 작품"
            )

            self.assertEqual(same_target, target)
            self.assertFalse(created_again)
            self.assertEqual(target.read_text(encoding="utf-8"), "사용자 수정본")


if __name__ == "__main__":
    unittest.main(verbosity=2)
