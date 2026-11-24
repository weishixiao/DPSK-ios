"""The version scheme, as arithmetic and as three files kept in step.

The rule the owner fixed - a build counter in the patch digit, rolling into the
minor at ten - is the kind of thing that is right for ten builds and wrong for the
eleventh, so it is tested rather than eyeballed:

    1.0.0 1.0.1 ... 1.0.9 1.1.0 ... 1.1.9 1.2.0 ... 1.9.9 2.0.0

The second half is the part that fails quietly: the guide states the same number in
its own READMEs, and `guide_sync.py --check` fails the build when they disagree
with the pubspec. A bump that forgets them looks correct until an unrelated job
turns red, so the coupling is pinned here.

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
        before, after = bump_version.bump(path, repo=pathlib.Path(tempfile.gettempdir()))
        self.assertEqual((before, after), ("1.0.0+1", "1.0.1+2"))
        self.assertEqual(path.read_text(encoding="utf-8"), "name: dsh_app\nversion: 1.0.1+2\ndescription: x\n")

    def test_the_roll_happens_with_the_build_number_alongside(self) -> None:
        path = self.write("version: 1.0.9+9\n")
        self.assertEqual(bump_version.bump(path, repo=pathlib.Path(tempfile.gettempdir())), ("1.0.9+9", "1.1.0+10"))

    def test_nothing_else_in_the_file_changes(self) -> None:
        body = "name: dsh_app\nversion: 1.2.3+4\n\nflutter:\n  uses-material-design: true\n"
        path = self.write(body)
        bump_version.bump(path, repo=pathlib.Path(tempfile.gettempdir()))
        self.assertEqual(path.read_text(encoding="utf-8"),
                         body.replace("version: 1.2.3+4", "version: 1.2.4+5"))

    def test_a_file_without_a_version_line_is_a_failure_not_a_guess(self) -> None:
        path = self.write("name: dsh_app\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(path, repo=pathlib.Path(tempfile.gettempdir()))

    def test_two_version_lines_are_refused_because_one_of_them_is_wrong(self) -> None:
        path = self.write("version: 1.0.0+1\nversion: 9.9.9+9\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(path, repo=pathlib.Path(tempfile.gettempdir()))

    def test_the_real_pubspec_parses(self) -> None:
        text = bump_version.PUBSPEC.read_text(encoding="utf-8")
        self.assertIsNotNone(bump_version.VERSION_LINE.search(text), "app/pubspec.yaml has no version line")


class GuideTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="bump-repo-"))
        self.addCleanup(lambda: __import__("shutil").rmtree(self.root, ignore_errors=True))
        (self.root / "app").mkdir()
        self.pubspec = self.root / "app" / "pubspec.yaml"
        self.pubspec.write_text("name: dsh_app\nversion: 1.0.8+8\n", encoding="utf-8", newline="\n")

    def guide(self, relative: str, version: str) -> pathlib.Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"# dsh-go\n\n> dsh-go {version}\n\nbody\n", encoding="utf-8", newline="\n")
        return path

    def test_every_readme_that_states_the_version_moves_with_it(self) -> None:
        guides = [self.guide(relative, "1.0.8") for relative in bump_version.GUIDES]
        bump_version.bump(self.pubspec, repo=self.root)
        for guide in guides:
            self.assertEqual(guide.read_text(encoding="utf-8"), "# dsh-go\n\n> dsh-go 1.0.9\n\nbody\n")

    def test_the_build_number_does_not_leak_into_the_guide(self) -> None:
        guide = self.guide(bump_version.GUIDES[0], "1.0.8")
        bump_version.bump(self.pubspec, repo=self.root)
        self.assertIn("> dsh-go 1.0.9", guide.read_text(encoding="utf-8"))
        self.assertNotIn("+", guide.read_text(encoding="utf-8"))

    def test_a_missing_guide_file_is_not_an_error(self) -> None:
        # A tree without the bundled skill (a fresh checkout of a branch that does
        # not build it) still has a pubspec worth bumping.
        bump_version.bump(self.pubspec, repo=self.root)
        self.assertIn("version: 1.0.9+9", self.pubspec.read_text(encoding="utf-8"))

    def test_a_guide_without_the_line_is_refused(self) -> None:
        path = self.root / bump_version.GUIDES[0]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("# dsh-go\n\nno version line here\n", encoding="utf-8", newline="\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(self.pubspec, repo=self.root)

    def info(self, version: str) -> pathlib.Path:
        path = self.root / bump_version.APP_INFO
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            "static const version = String.fromEnvironment('DSH_APP_VERSION', "
            f"defaultValue: '{version}');\n",
            encoding="utf-8",
            newline="\n",
        )
        return path

    def test_the_app_fallback_moves_with_the_build_number(self) -> None:
        info = self.info("1.0.8+8")
        self.guide(bump_version.GUIDES[0], "1.0.8")
        bump_version.bump(self.pubspec, repo=self.root)
        # The test that guards this file compares the whole X.Y.Z+B, so the
        # fallback must carry the build number, not just the dotted part.
        self.assertIn("defaultValue: '1.0.9+9'", info.read_text(encoding="utf-8"))

    def test_an_app_fallback_without_the_line_is_refused(self) -> None:
        self.guide(bump_version.GUIDES[0], "1.0.8")
        path = self.root / bump_version.APP_INFO
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("static const version = '1.0.8+8';\n", encoding="utf-8", newline="\n")
        with self.assertRaises(SystemExit):
            bump_version.bump(self.pubspec, repo=self.root)

    def test_the_real_app_info_parses(self) -> None:
        text = (bump_version.REPO / bump_version.APP_INFO).read_text(encoding="utf-8")
        self.assertIsNotNone(bump_version.INFO_LINE.search(text), "app_info.dart has no version fallback")


if __name__ == "__main__":
    unittest.main()