#!/usr/bin/env python3
"""Patch fwupd EFI variable with the correct ESP device path.

fwupd's uefi_capsule plugin writes zeroed-out HD device path nodes when
running inside a container on Talos Linux. This script fixes the fwupd
EFI variable so fwupdx64.efi can locate the staged capsule on reboot.

Runs inside the privileged fwupd helper pod (ubuntu:24.04 + python3).
"""

import argparse
import glob
import os
import struct
import subprocess
import sys

EFIVARS_DIR = "/sys/firmware/efi/efivars"

# UEFI device path: Media (0x04), Hard Drive (0x01), length 42 (0x002a)
HD_NODE_TYPE = 0x04
HD_NODE_SUBTYPE = 0x01
HD_NODE_LENGTH = 0x002A


def partuuid_to_efi_guid(partuuid: str) -> bytes:
    """Convert a PARTUUID string to EFI mixed-endian GUID bytes.

    EFI GUIDs store the first three groups in little-endian and the last
    two groups in big-endian (network) order.
    """
    parts = partuuid.split("-")
    if len(parts) != 5:
        raise ValueError(f"Invalid PARTUUID format: {partuuid}")
    return (
        bytes.fromhex(parts[0])[::-1]
        + bytes.fromhex(parts[1])[::-1]
        + bytes.fromhex(parts[2])[::-1]
        + bytes.fromhex(parts[3])
        + bytes.fromhex(parts[4])
    )


def find_fwupd_variable() -> str:
    """Find the fwupd-* EFI variable file."""
    matches = glob.glob(os.path.join(EFIVARS_DIR, "fwupd-*"))
    if not matches:
        print("FATAL: No fwupd EFI variable found", file=sys.stderr)
        sys.exit(1)
    if len(matches) > 1:
        print(f"WARNING: Multiple fwupd variables found, using first: {matches[0]}", file=sys.stderr)
    return matches[0]


def find_hd_node(data: bytearray, start: int = 4) -> int | None:
    """Find the HD device path node in the EFI variable data.

    Returns the offset of the node header, or None if not found.
    The first 4 bytes of the file are EFI attributes, so search starts at
    offset 4 by default.
    """
    for i in range(start, len(data) - 4):
        if (
            data[i] == HD_NODE_TYPE
            and data[i + 1] == HD_NODE_SUBTYPE
            and struct.unpack_from("<H", data, i + 2)[0] == HD_NODE_LENGTH
        ):
            return i
    return None


def patch_variable(varpath: str, partuuid: str, start_sector: int, size_sectors: int) -> None:
    """Patch the fwupd EFI variable with correct ESP partition geometry."""
    subprocess.run(["chattr", "-i", varpath], capture_output=True)

    with open(varpath, "rb") as f:
        data = bytearray(f.read())

    hd_offset = find_hd_node(data)
    if hd_offset is None:
        print("FATAL: HD device path node not found in EFI variable", file=sys.stderr)
        sys.exit(1)

    guid_bytes = partuuid_to_efi_guid(partuuid)

    struct.pack_into("<I", data, hd_offset + 4, 1)  # partition number
    struct.pack_into("<Q", data, hd_offset + 8, start_sector)  # start LBA
    struct.pack_into("<Q", data, hd_offset + 16, size_sectors)  # size
    data[hd_offset + 24 : hd_offset + 40] = guid_bytes  # signature

    with open(varpath, "wb") as f:
        f.write(data)

    # Verify
    with open(varpath, "rb") as f:
        vdata = f.read()
    pn = struct.unpack_from("<I", vdata, hd_offset + 4)[0]
    ps = struct.unpack_from("<Q", vdata, hd_offset + 8)[0]
    sz = struct.unpack_from("<Q", vdata, hd_offset + 16)[0]

    print(f"Patched: {os.path.basename(varpath)}")
    print(f"  Partition number: {pn}")
    print(f"  Start LBA:       {ps} ({hex(ps)})")
    print(f"  Size (sectors):  {sz} ({hex(sz)})")
    print(f"  PARTUUID:        {partuuid}")

    if pn != 1 or ps != start_sector or sz != size_sectors:
        print("FATAL: Verification failed — written values don't match", file=sys.stderr)
        sys.exit(1)

    print("EFI variable patched successfully.")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Patch fwupd EFI variable with correct ESP device path (Talos workaround)."
    )
    parser.add_argument("--partuuid", required=True, help="ESP partition UUID")
    parser.add_argument("--start-sector", type=int, required=True, help="ESP start sector (from sysfs)")
    parser.add_argument("--size-sectors", type=int, required=True, help="ESP size in sectors (from sysfs)")
    args = parser.parse_args()

    varpath = find_fwupd_variable()
    print(f"Found: {os.path.basename(varpath)}")
    patch_variable(varpath, args.partuuid, args.start_sector, args.size_sectors)


if __name__ == "__main__":
    main()
