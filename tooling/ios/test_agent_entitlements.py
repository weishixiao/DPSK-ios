#!/usr/bin/env python3
"""Tests for agent/service/check-entitlements.py.

The checker reads the entitlements out of the embedded code signature, so the
tests build a synthetic Mach-O with a real SuperBlob rather than mocking the
parser: a wrong offset or a missed load-command length shows up here, which is
the whole class of bug the checker exists to catch.
"""
from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CHECKER = REPO / "agent" / "service" / "check-entitlements.py"

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64_ABI64 = 12 | 0x01000000
CPU_SUBTYPE_ARM64E = 2
MH_EXECUTE = 2
LC_CODE_SIGNATURE = 0x1D
FAT_MAGIC = 0xCAFEBABE


def entitlements_xml(keys: list[str]) -> bytes:
    body = "".join("<key>%s</key><true/>" % key for key in keys)
    text = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>%s</dict></plist>\n' % body
    )
    return text.encode("utf-8")


def signature_blob(keys: list[str]) -> bytes:
    xml = entitlements_xml(keys)
    payload = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
    # One index entry: CSSLOT_ENTITLEMENTS (5) at offset 20.
    header = struct.pack(">III", 0xFADE0CC0, 12 + 8, 1)
    return header + struct.pack(">II", 5, 20) + payload


def thin_macho(keys: list[str], cputype: int = CPU_TYPE_ARM64_ABI64,
               cpusubtype: int = CPU_SUBTYPE_ARM64E, signed: bool = True) -> bytes:
    # 32-byte header + one linkedit_data_command, padded so the signature starts
    # at a realistic offset.
    header_size = 32
    command_size = 16
    text_size = 0x100
    blob = signature_blob(keys) if signed else b""
    commands_size = command_size if signed else 0
    header = struct.pack(
        "<IIIIIIII",
        MH_MAGIC_64, cputype, cpusubtype, MH_EXECUTE,
        1 if signed else 0, commands_size, 0, 0,
    )
    body = header
    data_offset = header_size + text_size
    if signed:
        body += struct.pack("<IIII", LC_CODE_SIGNATURE, command_size, data_offset, len(blob))
    body += b"\x00" * (text_size - (len(body) - header_size))
    body += blob
    return body


def fat_macho(keys: list[str]) -> bytes:
    slices = [thin_macho(keys, cpusubtype=0), thin_macho(keys, cpusubtype=CPU_SUBTYPE_ARM64E)]
    header = struct.pack(">II", FAT_MAGIC, len(slices))
    offset = 8 + 20 * len(slices)
    entries = b""
    payload = b""
    for index, part in enumerate(slices):
        entries += struct.pack(">IIIII", CPU_TYPE_ARM64_ABI64, index + 1 if index else 0, offset + len(payload), len(part), 12)
        payload += part
    return header + entries + payload


class CheckEntitlementsTest(unittest.TestCase):
    def run_checker(self, binary: Path, *extra: str, require: list[str] | None = None) -> subprocess.CompletedProcess:
        argv = [sys.executable, str(CHECKER), str(binary), *extra]
        for key in require or []:
            argv += ["--require", key]
        return subprocess.run(argv, capture_output=True, text=True)

    def write(self, name: str, data: bytes) -> Path:
        directory = Path(self.enterContext(tempfile.TemporaryDirectory()))
        path = directory / name
        path.write_bytes(data)
        return path

    def test_reports_entitlements_and_missing_keys(self) -> None:
        binary = self.write("agentd", thin_macho(["platform-application", "task_for_pid-allow"]))
        result = self.run_checker(binary, "--json", require=["platform-application", "task_for_pid-allow"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["architectures"][0]["arch"], "arm64e")
        self.assertEqual(report["architectures"][0]["missing"], [])
        self.assertIn("task_for_pid-allow", report["architectures"][0]["entitlements"])

    def test_missing_key_fails_and_names_it(self) -> None:
        binary = self.write("agentd", thin_macho(["platform-application"]))
        result = self.run_checker(binary, require=["platform-application", "com.apple.private.cs.debugger"])
        self.assertEqual(result.returncode, 1)
        self.assertIn("MISSING: com.apple.private.cs.debugger", result.stdout)

    def test_unsigned_binary_fails(self) -> None:
        binary = self.write("agentd", thin_macho([], signed=False))
        result = self.run_checker(binary)
        self.assertEqual(result.returncode, 1)
        self.assertIn("no embedded signature", result.stdout)

    def test_not_a_macho_is_a_read_error(self) -> None:
        binary = self.write("notes.txt", b"this is not a mach-o\n")
        result = self.run_checker(binary)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a Mach-O", result.stderr)

    def test_fat_binary_checks_every_slice(self) -> None:
        binary = self.write("agentd", fat_macho(["platform-application", "task_for_pid-allow", "com.apple.private.cs.debugger"]))
        result = self.run_checker(binary, "--json")
        self.assertEqual(result.returncode, 0, result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(len(report["architectures"]), 2)
        for entry in report["architectures"]:
            self.assertEqual(entry["missing"], [])
            self.assertTrue(entry["signed"])


if __name__ == "__main__":
    unittest.main()