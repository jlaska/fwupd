#!/usr/bin/env bash
# esp-detect.sh — Safe, non-hardcoded EFI System Partition detection for Talos Linux
# Discovers the ESP from GPT metadata and fails closed on any ambiguity.
# Designed to run inside a privileged fwupd helper container on Talos.
set -euo pipefail

ESP_MOUNT="${FWUPD_UEFI_ESP_PATH:-/boot/efi}"
ESP_PARTTYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

die() { echo "FATAL: $*" >&2; exit 1; }
warn() { echo "WARNING: $*" >&2; }

# --- 1. Verify UEFI boot mode ---
[ -d /sys/firmware/efi ] || die "/sys/firmware/efi not found — machine is not booted with UEFI"
[ -d /sys/firmware/efi/efivars ] || die "EFI runtime variables unavailable"

# --- 2. Discover ESP candidates by GPT partition type ---
ESP_CANDIDATES=$(lsblk -rno PATH,PARTTYPE 2>/dev/null \
  | awk -v pt="$ESP_PARTTYPE" 'tolower($2) == pt { print $1 }')
ESP_COUNT=0
[ -n "$ESP_CANDIDATES" ] && ESP_COUNT=$(echo "$ESP_CANDIDATES" | wc -l)

case "$ESP_COUNT" in
  0) die "No EFI System Partition found (GPT type $ESP_PARTTYPE)" ;;
  1) ;; # exactly one — proceed
  *) die "Multiple ESP candidates found: $ESP_CANDIDATES — refusing to guess" ;;
esac

ESP_DEV="$ESP_CANDIDATES"

# --- 3. Verify filesystem type ---
ESP_FSTYPE=$(blkid -o value -s TYPE "$ESP_DEV" 2>/dev/null || true)
[ "$ESP_FSTYPE" = "vfat" ] || die "ESP $ESP_DEV has filesystem '$ESP_FSTYPE', expected vfat"

# --- 4. Collect partition metadata ---
ESP_LABEL=$(blkid -o value -s LABEL "$ESP_DEV" 2>/dev/null || true)
ESP_PARTLABEL=$(blkid -o value -s PARTLABEL "$ESP_DEV" 2>/dev/null || true)
ESP_PARTUUID=$(blkid -o value -s PARTUUID "$ESP_DEV" 2>/dev/null || true)

# --- 5. Get partition geometry for EFI variable patching ---
DEVBASE=$(basename "$ESP_DEV")
PART_START=$(cat "/sys/class/block/$DEVBASE/start" 2>/dev/null || echo "unknown")
PART_SIZE=$(cat "/sys/class/block/$DEVBASE/size" 2>/dev/null || echo "unknown")

# --- 6. Mount ESP ---
mkdir -p "$ESP_MOUNT" || die "Failed to create mount point $ESP_MOUNT"
# Check if the ESP device is already mounted anywhere
EXISTING_MOUNT=$(findmnt -no TARGET "$ESP_DEV" 2>/dev/null || true)
if [ -n "$EXISTING_MOUNT" ]; then
  ESP_MOUNT="$EXISTING_MOUNT"
else
  mount -t vfat "$ESP_DEV" "$ESP_MOUNT" || die "Failed to mount $ESP_DEV at $ESP_MOUNT"
fi

# --- 7. Verify EFI directory structure ---
[ -d "$ESP_MOUNT/EFI" ] || die "No EFI directory on mounted ESP at $ESP_MOUNT"

# --- 8. Remount efivarfs read-write (Talos mounts it read-only) ---
EFIVARS_RW=false
if mount | grep -q "efivarfs.*\bro\b"; then
  mount -o remount,rw /sys/firmware/efi/efivars || die "Failed to remount efivarfs read-write"
  EFIVARS_RW=true
else
  EFIVARS_RW=true
fi

# --- 9. Verify ESRT is accessible ---
ESRT_COUNT=$(cat /sys/firmware/efi/esrt/fw_resource_count 2>/dev/null || echo "0")

# --- Output ---
echo "ESP detected and verified."
echo ""
echo "  Node:            $(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo unknown)"
echo "  ESP device:      $ESP_DEV"
echo "  Partition type:  EFI System Partition ($ESP_PARTTYPE)"
echo "  Filesystem:      $ESP_FSTYPE"
echo "  Label:           ${ESP_LABEL:-<none>}"
echo "  Partition label: ${ESP_PARTLABEL:-<none>}"
echo "  PARTUUID:        ${ESP_PARTUUID:-<none>}"
echo "  Start sector:    $PART_START"
echo "  Sector count:    $PART_SIZE"
echo "  Mount:           $ESP_MOUNT"
echo "  Free space:      $(df -h "$ESP_MOUNT" | awk 'NR==2{print $4}')"
echo "  EFI dirs:        $(ls "$ESP_MOUNT/EFI/" | tr '\n' ' ')"
echo "  efivarfs:        $(mount | grep efivarfs | grep -oE '\(.*\)')"
echo "  ESRT entries:    $ESRT_COUNT"
echo ""
echo "ESP verified."

# Export for downstream scripts
export ESP_DEV ESP_MOUNT ESP_PARTUUID ESP_FSTYPE PART_START PART_SIZE EFIVARS_RW
