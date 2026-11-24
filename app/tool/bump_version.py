#!/usr/bin/env python3
"""Advances the app version by one build.

The scheme, fixed by the owner: start at 1.0.0 and give every build the next
number - 1.0.1, 1.0.2, ... 1.0.9, then 1.1.0 - so the patch digit counts builds
and rolls into the minor at ten. The same rule continues upward for a scheme that
outlives this paragraph: 1.9.9 becomes 2.0.0.

The version lives in one place, `app/pubspec.yaml`, as `version: X.Y.Z+B`. The
trailing `+B` is the build number the stores and `CFBundleVersion` consume; it
increments with every bump too, because two builds must never share one.

The guide states the same number in a line of its own - `> dsh-go 1.0.0` in
`docs/guide/README.md` and `docs/guide/harmony/README.md`, mirrored into the
bundled skill - and `guide_sync.py --check` fails when the three disagree. That
check is why this script moves them together: a bump that leaves them behind
breaks the build one step later, in a job whose name says nothing about versions.

    python3 tool/bump_version.py          # bump and rewrite the files
    python3 tool/bump_version.py --print  # only show what the next version is
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve()
PUBSPEC = HERE.parents[1] / "pubspec.yaml"
REPO = HERE.parents[2]

VERSION_LINE = re.compile(
    r"^version:[ \t]*(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)\+(?P<build>\d+)[ \t]*$",
    re.MULTILINE,
)
GUIDE_LINE = re.compile(r"^> dsh-go \S+$", re.MULTILINE)

# The guide's own READMEs first, then the copy the app ships. `guide_sync.py`
# regenerates the last one from the first; it is listed so a bump that never runs
# the sync still leaves the tree consistent.
GUIDES = (
    "docs/guide/README.md",
    "docs/guide/harmony/README.md",
    "app/assets/skills/dsh-go-guide/README.md",
)


def next_version(version: str) -> str:
    """`1.0.0` -> `1.0.1`; `1.0.9` -> `1.1.0`; `1.9.9` -> `2.0.0`.

    The patch digit is a build counter, so it rolls at ten rather than at a
    hundred - that is the whole point of the scheme - and the roll carries on
    through the minor and the major for the same reason.
    """
    match = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", version)
    if match is None:
        raise SystemExit(f"version {version!r} is not three numbers separated by dots")
    major, minor, patch = (int(part) for part in match.groups())
    patch += 1
    if patch > 9:
        patch = 0
        minor += 1
        if minor > 9:
            minor = 0
            major += 1
    return f"{major}.{minor}.{patch}"


def bump(pubspec: pathlib.Path, repo: pathlib.Path | None = None) -> tuple[str, str]:
    """Rewrites the version everywhere it is stated; returns `(before, after)` with the build number."""
    text = pubspec.read_text(encoding="utf-8")
    match = VERSION_LINE.search(text)
    if match is None or len(VERSION_LINE.findall(text)) != 1:
        raise SystemExit(f"{pubspec} must contain exactly one `version: X.Y.Z+B` line")
    before = f"{match.group('major')}.{match.group('minor')}.{match.group('patch')}+{match.group('build')}"
    plain = next_version(before.split("+")[0])
    after = f"{plain}+{int(match.group('build')) + 1}"
    pubspec.write_text(VERSION_LINE.sub(f"version: {after}", text, count=1), encoding="utf-8", newline="\n")

    root = repo if repo is not None else pubspec.parents[1]
    for relative in GUIDES:
        guide = root / relative
        if not guide.is_file():
            continue
        guide_text = guide.read_text(encoding="utf-8")
        if not GUIDE_LINE.search(guide_text):
            raise SystemExit(f"{guide} has no `> dsh-go X.Y.Z` line to keep in step")
        guide.write_text(
            GUIDE_LINE.sub(f"> dsh-go {plain}", guide_text), encoding="utf-8", newline="\n"
        )
    return before, after


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print", dest="show", action="store_true", help="print the next version and exit")
    parser.add_argument("--pubspec", type=pathlib.Path, default=PUBSPEC, help="the pubspec to bump")
    parser.add_argument("--repo", type=pathlib.Path, default=None, help="the repo the guide paths are relative to")
    args = parser.parse_args(argv)

    if args.show:
        text = args.pubspec.read_text(encoding="utf-8")
        match = VERSION_LINE.search(text)
        if match is None:
            raise SystemExit(f"{args.pubspec} has no version line")
        print(next_version(f"{match.group('major')}.{match.group('minor')}.{match.group('patch')}"))
        return 0

    before, after = bump(args.pubspec, args.repo)
    print(f"{args.pubspec}: {before} -> {after}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))