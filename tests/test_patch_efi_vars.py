"""Unit tests for scripts/patch-efi-vars.py.

Tests run against a binary fixture and temporary files — no real EFI
variables are touched.
"""

import importlib.util
import struct
import sys
import types
from pathlib import Path
from unittest.mock import patch

import pytest

_REPO_ROOT = Path(__file__).resolve().parents[1]
_SCRIPT = _REPO_ROOT / "scripts" / "patch-efi-vars.py"
_FIXTURES = _REPO_ROOT / "tests" / "fixtures"


def _load_module(name: str, path: Path) -> types.ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


patcher = _load_module("patch_efi_vars", _SCRIPT)


class TestPartuuidToEfiGuid:
    def test_known_conversion(self):
        result = patcher.partuuid_to_efi_guid(
            "30ea38f7-bd27-4c0f-bfe1-249fea3904e0"
        )
        expected = bytes([
            0xf7, 0x38, 0xea, 0x30,
            0x27, 0xbd,
            0x0f, 0x4c,
            0xbf, 0xe1,
            0x24, 0x9f, 0xea, 0x39, 0x04, 0xe0,
        ])
        assert result == expected

    def test_all_zeros(self):
        result = patcher.partuuid_to_efi_guid(
            "00000000-0000-0000-0000-000000000000"
        )
        assert result == bytes(16)

    def test_invalid_format(self):
        with pytest.raises(ValueError, match="Invalid PARTUUID"):
            patcher.partuuid_to_efi_guid("not-a-valid-uuid")


class TestFindHdNode:
    def test_finds_hd_node_in_fixture(self):
        data = bytearray((_FIXTURES / "fwupd-efi-var.bin").read_bytes())
        offset = patcher.find_hd_node(data)
        assert offset is not None
        assert data[offset] == 0x04
        assert data[offset + 1] == 0x01
        length = struct.unpack_from("<H", data, offset + 2)[0]
        assert length == 0x002A

    def test_returns_none_when_no_hd_node(self):
        data = bytearray(b"\x07\x00\x00\x00" + b"\xff" * 100)
        assert patcher.find_hd_node(data) is None


class TestPatchVariable:
    def test_patches_correct_values(self, tmp_path):
        src = _FIXTURES / "fwupd-efi-var.bin"
        varfile = tmp_path / "fwupd-test-var"
        varfile.write_bytes(src.read_bytes())

        partuuid = "30ea38f7-bd27-4c0f-bfe1-249fea3904e0"
        start_sector = 2048
        size_sectors = 4302848

        with patch("patch_efi_vars.subprocess.run"):
            patcher.patch_variable(
                str(varfile), partuuid, start_sector, size_sectors
            )

        patched = bytearray(varfile.read_bytes())
        hd_offset = patcher.find_hd_node(patched)
        assert hd_offset is not None

        pn = struct.unpack_from("<I", patched, hd_offset + 4)[0]
        assert pn == 1

        start = struct.unpack_from("<Q", patched, hd_offset + 8)[0]
        assert start == 2048

        size = struct.unpack_from("<Q", patched, hd_offset + 16)[0]
        assert size == 4302848

        guid_bytes = patched[hd_offset + 24 : hd_offset + 40]
        expected_guid = patcher.partuuid_to_efi_guid(partuuid)
        assert guid_bytes == expected_guid

    def test_fails_on_missing_hd_node(self, tmp_path):
        varfile = tmp_path / "bad-var"
        varfile.write_bytes(b"\x07\x00\x00\x00" + b"\xff" * 100)

        with (
            patch("patch_efi_vars.subprocess.run"),
            pytest.raises(SystemExit),
        ):
            patcher.patch_variable(
                str(varfile),
                "30ea38f7-bd27-4c0f-bfe1-249fea3904e0",
                2048,
                4302848,
            )


class TestFixtureIntegrity:
    def test_fixture_has_zeroed_hd_node(self):
        data = bytearray((_FIXTURES / "fwupd-efi-var.bin").read_bytes())
        hd_offset = patcher.find_hd_node(data)
        assert hd_offset is not None

        pn = struct.unpack_from("<I", data, hd_offset + 4)[0]
        assert pn == 0

        start = struct.unpack_from("<Q", data, hd_offset + 8)[0]
        assert start == 0

        size = struct.unpack_from("<Q", data, hd_offset + 16)[0]
        assert size == 0
