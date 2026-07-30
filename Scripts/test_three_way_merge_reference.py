#!/usr/bin/env python3
"""Validate the shared merge fixture against the Windows reference code."""

from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_PATH = (
    ROOT / "WriterPadTests" / "Fixtures" / "three_way_merge_cases.json"
)
REFERENCE_PATH = ROOT / "참조파일" / "three_way_merge.py"


def _load_reference():
    spec = importlib.util.spec_from_file_location(
        "writerpad_windows_three_way_merge",
        REFERENCE_PATH,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {REFERENCE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _materialize(generator):
    if generator["kind"] != "numberedLines":
        raise ValueError(f"unsupported generator: {generator['kind']}")
    line_count = generator["lineCount"]
    base_lines = [f"공통 {index:05d} 😀\n" for index in range(line_count)]
    local_lines = list(base_lines)
    remote_lines = list(base_lines)
    for replacement in generator["localReplacements"]:
        local_lines[replacement["index"]] = replacement["value"]
    for replacement in generator["remoteReplacements"]:
        remote_lines[replacement["index"]] = replacement["value"]
    return "".join(base_lines), "".join(local_lines), "".join(remote_lines)


class SharedThreeWayMergeFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
        cls.reference = _load_reference()

    def test_literal_cases(self):
        for case in self.fixture["cases"]:
            with self.subTest(case=case["id"]):
                result = self.reference.three_way_merge(
                    case["base"],
                    case["local"],
                    case["remote"],
                )
                self.assertEqual(result.content, case["expectedContent"])
                self.assertEqual(
                    result.has_conflicts,
                    case["expectedHasConflicts"],
                )
                self.assertEqual(
                    result.conflict_count,
                    case["expectedConflictCount"],
                )

    def test_generated_large_cases(self):
        for case in self.fixture["generatedCases"]:
            with self.subTest(case=case["id"]):
                base, local, remote = _materialize(case["generator"])
                result = self.reference.three_way_merge(base, local, remote)
                digest = hashlib.sha256(result.content.encode("utf-8")).hexdigest()
                self.assertEqual(digest, case["expectedContentSHA256"])
                self.assertEqual(
                    len(result.content.encode("utf-8")),
                    case["expectedUTF8ByteCount"],
                )
                self.assertEqual(
                    result.has_conflicts,
                    case["expectedHasConflicts"],
                )
                self.assertEqual(
                    result.conflict_count,
                    case["expectedConflictCount"],
                )


if __name__ == "__main__":
    unittest.main()
