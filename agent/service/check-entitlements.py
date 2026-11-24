#!/usr/bin/env python3
"""Checks the entitlements that are actually *inside* a built Mach-O.

The plist next to the sources says what the daemon should carry; only the
signature inside the binary says what it does carry. `ldid -S` that silently
dropped a key, a build that forgot `_CODESIGN_FLAGS`, or an install that copied
an older binary all look identical from the source tree, so the check reads the
LC_CODE_SIGNATURE blob the way `codesign -d --entitlements` does.

    python3 check-entitlements.py <binary> [--require KEY ...] [--json]

Exit status is 0 when the binary carries every required key, 1 when one is
missing (the missing keys are named), and 2 when the file cannot be read as a
Mach-O or has no signature. Defaults to the set agentd needs; pass --require to
check a different product (the app, a tweaked payload, ...).
"""
from __future__ import annotations

import argparse
import json
import struct
import sys

MH_MAGIC = 0xFEEDFACE
MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM = 0xBEBAFECA
FAT_CIGAM_64 = 0xBFBAFECA

LC_CODE_SIGNATURE = 0x1D

CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_ENTITLEMENTS = 0xFADE7171
CSSLOT_ENTITLEMENTS = 5

CPU_ARCH_ABI64 = 0x01000000
CPU_TYPE_ARM64 = 12
ARM64_SUBTYPES = {0: "arm64", 1: "arm64v8", 2: "arm64e"}

# What the daemon cannot do its job without. Kept here rather than in the
# Makefile so the workflow, install.sh and a person with a shell all check the
# same list.
AGENTD_REQUIRED = [
    "platform-application",
    "task_for_pid-allow",
    "com.apple.private.cs.debugger",
]


class Slice:
    def __init__(self, name: str, offset: int, size: int, data: bytes):
        self.name = name
        self.offset = offset
        self.size = size
        self.data = data


def arch_name(cputype: int, cpusubtype: int) -> str:
    if cputype == CPU_TYPE_ARM64 | CPU_ARCH_ABI64:
        return ARM64_SUBTYPES.get(cpusubtype & 0x00FFFFFF, "arm64")
    return "cputype-%d" % cputype


def slices(blob: bytes) -> list[Slice]:
    """Returns every architecture in the file, thin files included."""
    if len(blob) < 8:
        raise ValueError("file is shorter than a Mach-O header")
    magic, = struct.unpack_from(">I", blob, 0)

    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        nfat, = struct.unpack_from(">I", blob, 4)
        wide = magic == FAT_MAGIC_64
        entry = 32 if wide else 20
        out = []
        for index in range(nfat):
            base = 8 + index * entry
            if wide:
                cputype, cpusubtype, offset, size = struct.unpack_from(">IIQQ", blob, base)
            else:
                cputype, cpusubtype, offset, size = struct.unpack_from(">IIII", blob, base)
            out.append(Slice(arch_name(cputype, cpusubtype), offset, size, blob[offset:offset + size]))
        return out

    if magic in (FAT_CIGAM, FAT_CIGAM_64):
        # Same layout, opposite endianness: read it as little-endian pairs.
        nfat, = struct.unpack_from("<I", blob, 4)
        wide = magic == FAT_CIGAM_64
        entry = 32 if wide else 20
        out = []
        for index in range(nfat):
            base = 8 + index * entry
            if wide:
                cputype, cpusubtype, offset, size = struct.unpack_from("<IIQQ", blob, base)
            else:
                cputype, cpusubtype, offset, size = struct.unpack_from("<IIII", blob, base)
            out.append(Slice(arch_name(cputype, cpusubtype), offset, size, blob[offset:offset + size]))
        return out

    little = struct.unpack_from("<I", blob, 0)[0]
    if little in (MH_MAGIC, MH_MAGIC_64):
        cputype, cpusubtype = struct.unpack_from("<II", blob, 4)
        return [Slice(arch_name(cputype, cpusubtype), 0, len(blob), blob)]
    if magic in (MH_MAGIC, MH_MAGIC_64):
        cputype, cpusubtype = struct.unpack_from(">II", blob, 4)
        return [Slice(arch_name(cputype, cpusubtype), 0, len(blob), blob)]
    raise ValueError("not a Mach-O: magic 0x%08x" % magic)


def code_signature(slice_data: bytes) -> tuple[int, int] | None:
    """Returns (dataoff, datasize) of LC_CODE_SIGNATURE, or None."""
    if len(slice_data) < 28:
        return None
    magic_le = struct.unpack_from("<I", slice_data, 0)[0]
    if magic_le in (MH_MAGIC, MH_MAGIC_64):
        endian = "<"
        header = 32 if magic_le == MH_MAGIC_64 else 28
    else:
        magic_be = struct.unpack_from(">I", slice_data, 0)[0]
        if magic_be not in (MH_MAGIC, MH_MAGIC_64):
            return None
        endian = ">"
        header = 32 if magic_be == MH_MAGIC_64 else 28
    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds = struct.unpack_from(endian + "IIIIII", slice_data, 0)
    offset = header
    for _ in range(ncmds):
        if offset + 8 > len(slice_data):
            return None
        cmd, cmdsize = struct.unpack_from(endian + "II", slice_data, offset)
        if cmdsize < 8:
            return None
        if cmd == LC_CODE_SIGNATURE:
            if offset + 16 > len(slice_data):
                return None
            dataoff, datasize = struct.unpack_from(endian + "II", slice_data, offset + 8)
            return dataoff, datasize
        offset += cmdsize
    return None


def entitlements_blob(slice_data: bytes) -> bytes | None:
    located = code_signature(slice_data)
    if located is None:
        return None
    dataoff, datasize = located
    blob = slice_data[dataoff:dataoff + datasize]
    if len(blob) < 12:
        return None
    magic, length, count = struct.unpack_from(">III", blob, 0)
    if magic != CSMAGIC_EMBEDDED_SIGNATURE:
        return None
    for index in range(count):
        slot_type, slot_offset = struct.unpack_from(">II", blob, 12 + index * 8)
        if slot_type != CSSLOT_ENTITLEMENTS:
            continue
        blob_magic, blob_length = struct.unpack_from(">II", blob, slot_offset)
        if blob_magic != CSMAGIC_ENTITLEMENTS:
            return None
        return blob[slot_offset + 8:slot_offset + blob_length]
    return None


def entitlement_keys(xml: bytes) -> list[str]:
    """Every <key> in the entitlements dict, in file order.

    The dict is flat (arrays carry strings, not dictionaries), so the keys of
    the outermost dict are every <key> tag in the blob.
    """
    text = xml.decode("utf-8", "replace")
    keys = []
    cursor = 0
    opening = "<key>"
    closing = "</key>"
    while True:
        start = text.find(opening, cursor)
        if start < 0:
            break
        end = text.find(closing, start + len(opening))
        if end < 0:
            break
        keys.append(text[start + len(opening):end].strip())
        cursor = end + len(closing)
    return keys


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary")
    parser.add_argument("--require", action="append", default=None,
                        help="entitlement that must be present; repeatable")
    parser.add_argument("--json", action="store_true", help="print the report as JSON")
    options = parser.parse_args(argv[1:])

    required = options.require if options.require else AGENTD_REQUIRED

    try:
        with open(options.binary, "rb") as handle:
            blob = handle.read()
        parts = slices(blob)
    except (OSError, ValueError) as error:
        print("cannot read %s as a Mach-O: %s" % (options.binary, error), file=sys.stderr)
        return 2

    report = {"binary": options.binary, "required": required, "architectures": []}
    failures = 0
    for part in parts:
        xml = entitlements_blob(part.data)
        keys = entitlement_keys(xml) if xml else []
        missing = [key for key in required if key not in keys]
        if missing or xml is None:
            failures += 1
        report["architectures"].append({
            "arch": part.name,
            "signed": xml is not None,
            "entitlements": keys,
            "missing": missing,
        })

    if options.json:
        print(json.dumps(report, indent=2))
    else:
        for entry in report["architectures"]:
            if not entry["signed"]:
                print("%s (%s): no embedded signature - was it signed with ldid -S?" % (options.binary, entry["arch"]))
                continue
            print("%s (%s): %d entitlements" % (options.binary, entry["arch"], len(entry["entitlements"])))
            for key in entry["entitlements"]:
                print("  %s" % key)
            for key in entry["missing"]:
                print("  MISSING: %s" % key)

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))