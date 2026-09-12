#!/usr/bin/env bash
# fwupd-container — CLI wrapper for fwupd in privileged Kubernetes pods.
#
# Handles container-specific workarounds: ESP auto-detection, EFI variable
# patching, and boot entry fixing. All structured output goes to stdout as
# JSON; progress and diagnostics go to stderr.
set -euo pipefail

VERSION="${FWUPD_CONTAINER_VERSION:-dev}"
NODE_NAME="${NODE_NAME:-$(hostname 2>/dev/null || echo unknown)}"

# ---------------------------------------------------------------------------
# Logging (all to stderr so stdout stays clean for JSON)
# ---------------------------------------------------------------------------
_ts() { date +%H:%M:%S; }
log()  { echo -e "[$(_ts)] $*" >&2; }
ok()   { echo -e "[$(_ts)] ✅ $*" >&2; }
warn() { echo -e "[$(_ts)] ⚠️  $*" >&2; }
die()  { echo -e "[$(_ts)] ❌ $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# ESP init — common setup for all subcommands
# ---------------------------------------------------------------------------
ESP_DEV=""
ESP_PARTUUID=""
PART_START=""
PART_SIZE=""
ESP_MOUNT="${FWUPD_UEFI_ESP_PATH:-/boot/efi}"

esp_init() {
    [ -d /sys/firmware/efi ] || die "Not booted with UEFI — /sys/firmware/efi not found"
    [ -d /sys/firmware/efi/efivars ] || die "EFI runtime variables unavailable"

    log "Detecting EFI System Partition..."
    local esp_output
    esp_output=$(esp-detect 2>&1) || die "ESP detection failed"

    ESP_DEV=$(echo "$esp_output" | grep "ESP device:" | sed 's/.*ESP device:\s*//' | xargs)
    ESP_PARTUUID=$(echo "$esp_output" | grep "PARTUUID:" | sed 's/.*PARTUUID:\s*//' | xargs)
    PART_START=$(echo "$esp_output" | grep "Start sector:" | sed 's/.*Start sector:\s*//' | xargs)
    PART_SIZE=$(echo "$esp_output" | grep "Sector count:" | sed 's/.*Sector count:\s*//' | xargs)
    ESP_MOUNT=$(echo "$esp_output" | grep "Mount:" | sed 's/.*Mount:\s*//' | xargs)

    [ -n "$ESP_DEV" ] || die "ESP device not detected"
    ok "ESP: ${ESP_DEV} (PARTUUID=${ESP_PARTUUID})"
}

esp_info_json() {
    jq -n \
        --arg dev "$ESP_DEV" \
        --arg partuuid "$ESP_PARTUUID" \
        --arg start "$PART_START" \
        --arg size "$PART_SIZE" \
        --arg mount "$ESP_MOUNT" \
        '{device: $dev, partuuid: $partuuid, start_sector: ($start | tonumber), size_sectors: ($size | tonumber), mount: $mount}'
}

# ---------------------------------------------------------------------------
# fwupd helpers
# ---------------------------------------------------------------------------
refresh_lvfs() {
    log "Enabling LVFS remote and refreshing metadata..."
    fwupdtool enable-remote lvfs >/dev/null 2>&1 || true
    fwupdtool refresh >/dev/null 2>&1 || true
    ok "LVFS metadata refreshed"
}

find_system_firmware_id() {
    local devices_json="$1"
    echo "$devices_json" | jq -r '
        .Devices[]
        | select(.Name == "System Firmware" or (.Plugin == "uefi_capsule" and (.Name | startswith("System Firmware"))))
        | .DeviceId
    ' | head -1
}

find_system_firmware_version() {
    local devices_json="$1"
    echo "$devices_json" | jq -r '
        .Devices[]
        | select(.Name == "System Firmware" or (.Plugin == "uefi_capsule" and (.Name | startswith("System Firmware"))))
        | .Version
    ' | head -1
}

# ---------------------------------------------------------------------------
# Boot entry fix — workaround for fwupd creating broken boot entries in
# containers. Deletes the broken entry, recreates with the correct disk
# path, and sets BootNext.
# ---------------------------------------------------------------------------
parent_disk() {
    local esp_dev="$1"
    if [[ "$esp_dev" =~ ^(/dev/nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
        PARENT_DISK="${BASH_REMATCH[1]}"
        PART_NUM="${BASH_REMATCH[2]}"
    elif [[ "$esp_dev" =~ ^(.+?)([0-9]+)$ ]]; then
        PARENT_DISK="${BASH_REMATCH[1]}"
        PART_NUM="${BASH_REMATCH[2]}"
    else
        die "Cannot derive parent disk from ESP device: $esp_dev"
    fi
}

fix_boot_entry() {
    local esp_dev="$1"
    local disk part_num

    parent_disk "$esp_dev"
    disk="$PARENT_DISK"
    part_num="$PART_NUM"

    log "Fixing fwupd boot entry (disk=${disk}, partition=${part_num})..."

    local efi_output fwupd_entry
    efi_output=$(efibootmgr 2>&1) || true
    fwupd_entry=$(echo "$efi_output" | grep -iE "Linux Firmware Updater|fwupd" | grep -oP 'Boot\K\w+' | head -1) || true

    if [ -z "$fwupd_entry" ]; then
        warn "No fwupd boot entry found — fwupdtool may not have created one"
        return 0
    fi

    # Delete the broken entry
    log "Deleting broken boot entry Boot${fwupd_entry}"
    efibootmgr -b "$fwupd_entry" -B >&2

    # Detect the correct EFI shim path
    local efi_shim=""
    for candidate in \
        "${ESP_MOUNT}/EFI/fedora/fwupdx64.efi" \
        "${ESP_MOUNT}/EFI/ubuntu/fwupdx64.efi" \
        "${ESP_MOUNT}/EFI/Linux Firmware Updater/fwupdx64.efi"; do
        if [ -f "$candidate" ]; then
            efi_shim="${candidate#"${ESP_MOUNT}"}"
            efi_shim="${efi_shim//\//\\}"
            break
        fi
    done
    [ -n "$efi_shim" ] || die "fwupd EFI shim not found on ESP"

    # Recreate with correct disk reference
    log "Creating corrected boot entry: disk=${disk} partition=${part_num} loader=${efi_shim}"
    local create_output
    create_output=$(efibootmgr -c -d "$disk" -p "$part_num" \
        -L "Linux Firmware Updater" \
        -l "$efi_shim" 2>&1) || die "Failed to create boot entry"

    # Find new entry number
    local new_entry
    new_entry=$(echo "$create_output" | grep "Linux Firmware Updater" | grep -oP 'Boot\K\w+' | head -1) || true
    if [ -z "$new_entry" ]; then
        new_entry=$(efibootmgr 2>&1 | grep "Linux Firmware Updater" | grep -oP 'Boot\K\w+' | head -1) || true
    fi
    [ -n "$new_entry" ] || die "Could not find newly created boot entry"

    # Set BootNext
    efibootmgr -n "$new_entry" >&2
    ok "BootNext set to Boot${new_entry} (Linux Firmware Updater)"
    echo "$new_entry"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_esp_info() {
    esp_init
    esp_info_json
}

cmd_get_devices() {
    esp_init
    log "Querying fwupd devices..."
    local devices_json
    devices_json=$(fwupdtool get-devices --json 2>/dev/null)

    local sys_fw_id sys_fw_version
    sys_fw_id=$(find_system_firmware_id "$devices_json")
    sys_fw_version=$(find_system_firmware_version "$devices_json")

    jq -n \
        --arg hostname "$NODE_NAME" \
        --argjson esp "$(esp_info_json)" \
        --arg sys_fw_id "${sys_fw_id:-}" \
        --arg sys_fw_version "${sys_fw_version:-}" \
        --argjson devices "$devices_json" \
        '{
            hostname: $hostname,
            esp: $esp,
            system_firmware: {
                device_id: $sys_fw_id,
                version: $sys_fw_version
            },
            devices: $devices.Devices
        }'
}

cmd_get_updates() {
    esp_init
    refresh_lvfs

    log "Checking for firmware updates..."
    local updates_text exit_code=0
    updates_text=$(fwupdtool get-updates 2>&1) || exit_code=$?

    # Exit code 2 means "nothing to do"
    if [ "$exit_code" -eq 2 ] || echo "$updates_text" | grep -q "No updatable devices"; then
        ok "All firmware is up to date"
        jq -n '{updates: [], up_to_date: true}'
        return 0
    elif [ "$exit_code" -ne 0 ]; then
        die "fwupdtool get-updates failed (exit $exit_code): $updates_text"
    fi

    # Try JSON output for structured data
    local updates_json exit_code_json=0
    updates_json=$(fwupdtool get-updates --json 2>/dev/null) || exit_code_json=$?

    if [ "$exit_code_json" -eq 0 ] && echo "$updates_json" | jq . >/dev/null 2>&1; then
        echo "$updates_json" | jq '{updates: .Devices, up_to_date: false}'
    else
        # Fallback: parse text output for version info
        local available_version
        available_version=$(echo "$updates_text" | grep -A5 "System Firmware" | grep "New version:" | head -1 | sed 's/.*New version:\s*//' | xargs) || true
        jq -n \
            --arg version "${available_version:-unknown}" \
            --arg raw "$updates_text" \
            '{updates: [{name: "System Firmware", new_version: $version}], up_to_date: false, raw_output: $raw}'
    fi
}

cmd_get_history() {
    esp_init
    log "Querying firmware update history..."
    local history_json exit_code=0
    history_json=$(fwupdtool get-history --json 2>/dev/null) || exit_code=$?

    if [ "$exit_code" -eq 0 ] && echo "$history_json" | jq . >/dev/null 2>&1; then
        echo "$history_json"
    else
        local history_text
        history_text=$(fwupdtool get-history 2>&1) || true
        jq -n --arg raw "$history_text" '{raw_output: $raw}'
    fi
}

cmd_update() {
    local device_id=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --device-id) device_id="$2"; shift 2 ;;
            *) die "Unknown option: $1" ;;
        esac
    done

    esp_init
    refresh_lvfs

    # Auto-detect system firmware if no device ID specified
    if [ -z "$device_id" ]; then
        log "Auto-detecting system firmware device..."
        local devices_json
        devices_json=$(fwupdtool get-devices --json 2>/dev/null)
        device_id=$(find_system_firmware_id "$devices_json")
        [ -n "$device_id" ] || die "System firmware not detected by fwupd"
    fi

    local current_version
    current_version=$(fwupdtool get-devices --json 2>/dev/null | jq -r ".Devices[] | select(.DeviceId == \"$device_id\") | .Version") || true
    log "Current firmware version: ${current_version:-unknown}"

    # Check for available updates
    local updates_text exit_code=0
    updates_text=$(fwupdtool get-updates 2>&1) || exit_code=$?
    if [ "$exit_code" -eq 2 ]; then
        ok "Firmware is already current (${current_version:-unknown})"
        jq -n \
            --arg device_id "$device_id" \
            --arg version "${current_version:-unknown}" \
            '{staged: false, device_id: $device_id, current_version: $version, reason: "already up to date"}'
        return 0
    fi

    # Parse target version
    local target_version
    target_version=$(echo "$updates_text" | grep -A5 "System Firmware" | grep "New version:" | head -1 | sed 's/.*New version:\s*//' | xargs) || true
    log "Staging firmware update: ${current_version:-unknown} → ${target_version:-unknown}"

    # Stage the firmware capsule
    fwupdtool update --no-reboot-check "$device_id" 2>&1 >&2
    ok "Firmware capsule staged"

    # Patch EFI variables (container workaround)
    if [ -n "$ESP_PARTUUID" ] && [ -n "$PART_START" ] && [ -n "$PART_SIZE" ]; then
        log "Patching fwupd EFI variable with correct ESP geometry..."
        patch-efi-vars \
            --partuuid "$ESP_PARTUUID" \
            --start-sector "$PART_START" \
            --size-sectors "$PART_SIZE" >&2
        ok "EFI variable patched"
    else
        warn "ESP geometry incomplete — skipping EFI variable patch"
    fi

    # Fix the boot entry
    local boot_next=""
    boot_next=$(fix_boot_entry "$ESP_DEV") || true

    # Verify capsule on ESP
    log "Verifying capsule on ESP..."
    local capsule_found=false
    if find "${ESP_MOUNT}" -name "*.cap" -type f 2>/dev/null | grep -q .; then
        capsule_found=true
        ok "Capsule verified on ESP"
    else
        warn "No capsule file found on ESP — update may not apply"
    fi

    jq -n \
        --arg device_id "$device_id" \
        --arg current "$current_version" \
        --arg target "${target_version:-unknown}" \
        --arg boot_next "${boot_next:-}" \
        --argjson capsule_verified "$capsule_found" \
        '{
            staged: true,
            device_id: $device_id,
            current_version: $current,
            target_version: $target,
            boot_next: $boot_next,
            capsule_verified: $capsule_verified
        }'
}

cmd_version() {
    local fwupd_version
    fwupd_version=$(fwupdtool --version 2>/dev/null | head -1 || echo "unknown")
    jq -n \
        --arg container_version "$VERSION" \
        --arg fwupd_version "$fwupd_version" \
        --arg node_name "$NODE_NAME" \
        '{container_version: $container_version, fwupd_version: $fwupd_version, node_name: $node_name}'
}

cmd_help() {
    cat >&2 <<'EOF'
fwupd-container — fwupd in a privileged Kubernetes pod

Usage: fwupd-container <subcommand> [options]

Subcommands:
  get-devices              List firmware devices (JSON)
  get-updates              Check LVFS for available updates (JSON)
  get-history              Show firmware update history (JSON)
  update [--device-id ID]  Stage firmware + apply container workarounds (JSON)
  esp-info                 Show EFI System Partition details (JSON)
  version                  Show container and fwupd versions (JSON)
  help                     Show this help

The container must run with:
  - privileged: true
  - hostPID: true
  - Host mounts: /sys/firmware, /sys/bus, /sys/class, /sys/devices, /dev, /run/udev

Environment:
  FWUPD_UEFI_ESP_PATH              ESP mount point (default: /boot/efi)
  FWUPD_CONTAINER_VERSION          Container version (set at build time)
  NODE_NAME                        Node name for output (default: hostname)

All structured output goes to stdout as JSON.
Progress and diagnostics go to stderr.
EOF
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-help}" in
    get-devices)  cmd_get_devices ;;
    get-updates)  cmd_get_updates ;;
    get-history)  cmd_get_history ;;
    update)       shift; cmd_update "$@" ;;
    esp-info)     cmd_esp_info ;;
    version)      cmd_version ;;
    help|--help)  cmd_help ;;
    *)            die "Unknown subcommand: $1 (try 'help')" ;;
esac
