"""The version scheme, as arithmetic.

The rule the owner fixed - a build counter in the patch digit, rolling into the
minor at ten - is the kind of thing that is right for ten builds and wrong for the
eleventh, so it is tested rather than eyeballed:

    1.0.0 1.0.1 ... 1.0.9 1.1.0 ... 1.1.9 1.2.0 ... 1.9.9 2.0.0

Loaded by path because the script lives under `app/tool/` with the other tools
rather than on the import path.
"""
from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = REPO / "app" / "tool" / "bump_version.py"

spec = importlib.util.spec_from_file_location("bump_version", SCRIPT)
if spec is None or spec.loader is None:  # pragma: no cover - broken checkout
    raise SystemExit(f"cannot load {SCRIPT}")
bump_version = importlib.util.module_from_spec(spec)
sys.modules["bump_version"] = bump_version
spec.loader.exec_module(bump_version)


class NextVersionTest(unittest.TestCase):
    def test_the_first_build_after_the_baseline(self) -> None:
        self.assertEqual(bump_version.next_version("1.0.0"), "1.0.1")

    def test_the_sequence_the_owner_wrote_out(self) -> None:
        sequence = [bump_version.next_version(version) for version in
                    ("1.0.0", "1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5", "1.0.6", "1.0.7", "1.0.8")]
        self.assertEqual(sequence, ["1.0.1", "1.0.2", "1.0.3", "1.0.4", "1.0.5",
                                    "1.0.6", "1.0.7", "1.0.8", "1.0.9"])

    def test_nine_rolls_into_the_next_minor(self) -> None:
        self.assertEqual(bump_version.next_version("1.0.9"), "1.1.0")
        self.assertEqual(bump_version.next_version("1.1.9"), "1.2.0")
        self.assertEqual(bump_version.next_version("1.8.9"), "1.9.0")

    def test_the_roll_carries_through_the_minor_too(self) -> None:
        self.assertEqual(bump_version.next_version("1.9.9"), "2.0.0")

    def test_a_ten_never_appears_in_the_patch(self) -> None:
        version = "1.0.0"
        for _ in range(200):
            version = bump_version.next_version(version)
            self.assertLessEqual(int(version.split(".")[2]), 9, version)

    def test_nonsense_is_refused_rather_than_guessed(self) -> None:
        for bad in ("1.0", "1.0.0.0", "one.two.three", ""):
            with self.assertRaises(SystemExit):
                bump_version.next_version(bad)


class BumpTest(unittest.TestCase):
    def write(self, text: str) -> pathlib.Path:
        handle = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False, encoding="utf-8", newline="\n")
        handle.write(text)
        handle.close()
        path = pathlib.Path(handle.name)
        self.addCleanup(path.unlink)
        return path

    def test_the_version_line_and_the_build_number_both_move(self) -> None:
        path = self.write("name: dsh_app\nversion: 1.0.0+1\ndescription: x\n")
        before, after = bump_version.bump(path)
        self.assertEqual((before, after), ("1.0.0+1", "1.0.1+2"))
        self.assertEqual(path.read_text(encoding="utf-8"), "name: dsh_app\nversion: 1.0.1+2\ndescription: x\n")

    def test_the_roll_happens_with_the_build_number_alongside(self) -> None:
        path = self.write("version: 1.0.9+9\n")
        self.assertEqual(bump_version.bump(path), ("1.0.9+9", "1.1.0+10"))

    def test_nothing_else_in_the_file_changes(self) -> None:
        body = "name: dsh_app\nversion: 1.2.3+4\n\nflutter:\n  uses-material-design: true\n"
        path = self.write(body)
        bump_version.bump(path)
        self.assertEqual(path.read_text(encoding="utf-8"),
                         body.replace("version: 1.2.3+4", "version: 1.2.4+5"))

    def test_a_file_without_a_version_line_is_a_failure_not_a_guess(self) -> None:
        path = self.write("name: dsh_app\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(path)

    def test_two_version_lines_are_refused_because_one_of_them_is_wrong(self) -> None:
        path = self.write("version: 1.0.0+1\nversion: 9.9.9+9\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(path)

    def test_the_real_pubspec_parses(self) -> None:
        text = bump_version.PUBSPEC.read_text(encoding="utf-8")
        self.assertIsNotNone(bump_version.VERSION_LINE.search(text), "app/pubspec.yaml has no version line")


if __name__ == "__main__":
    unittest.main()