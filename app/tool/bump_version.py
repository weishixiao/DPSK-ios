#!/usr/bin/env python3
"""Advances the app version by one build.

The scheme, fixed by the owner: start at 1.0.0 and give every build the next
number - 1.0.1, 1.0.2, ... 1.0.9, then 1.1.0 - so the patch digit counts builds
and rolls into the minor at ten. The same rule continues upward for a scheme that
outlives this paragraph: 1.9.9 becomes 2.0.0.

The version lives in one place, `app/pubspec.yaml`, as `version: X.Y.Z+B`. The
trailing `+B` is the build number the stores and `CFBundleVersion` consume; it
increments with every bump too, because two builds must never share one.

    python3 tool/bump_version.py          # bump and rewrite pubspec.yaml
    python3 tool/bump_version.py --print  # only show what the next version is
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

PUBSPEC = pathlib.Path(__file__).resolve().parents[1] / "pubspec.yaml"
VERSION_LINE = re.compile(
    r"^version:[ \t]*(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)\+(?P<build>\d+)[ \t]*$",
    re.MULTILINE,
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


def bump(path: pathlib.Path) -> tuple[str, str]:
    """Rewrite the version line in `path`; returns `(before, after)` including the build number."""
    text = path.read_text(encoding="utf-8")
    match = VERSION_LINE.search(text)
    if match is None or len(VERSION_LINE.findall(text)) != 1:
        raise SystemExit(f"{path} must contain exactly one `version: X.Y.Z+B` line")
    before = f"{match.group('major')}.{match.group('minor')}.{match.group('patch')}+{match.group('build')}"
    after = f"{next_version(before.split('+')[0])}+{int(match.group('build')) + 1}"
    new_text = VERSION_LINE.sub(f"version: {after}", text, count=1)
    path.write_text(new_text, encoding="utf-8", newline="\n")
    return before, after


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--print", dest="show", action="store_true", help="print the next version and exit")
    parser.add_argument("--pubspec", type=pathlib.Path, default=PUBSPEC, help="the pubspec to bump")
    args = parser.parse_args(argv)

    if args.show:
        text = args.pubspec.read_text(encoding="utf-8")
        match = VERSION_LINE.search(text)
        if match is None:
            raise SystemExit(f"{args.pubspec} has no version line")
        print(next_version(f"{match.group('major')}.{match.group('minor')}.{match.group('patch')}"))
        return 0

    before, after = bump(args.pubspec)
    print(f"{args.pubspec}: {before} -> {after}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))