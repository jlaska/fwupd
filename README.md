# fwupd Container

Minimal container image for running [fwupd](https://github.com/fwupd/fwupd) firmware management inside privileged Kubernetes pods. Includes workarounds for fwupd's uefi_capsule plugin when running in containers (ESP auto-detection, EFI variable patching, boot entry fixing).

## Quick Start

```bash
# Check firmware on a specific node
kubectl apply -f deploy/namespace.yaml
kubectl apply -f deploy/job.yaml  # edit NODE_NAME first

# Or run interactively
kubectl run fwupd-check \
  --image=ghcr.io/jlaska/fwupd:v1.0.0 \
  --namespace=firmware-maintenance \
  --overrides='<see deploy/job.yaml for required pod spec>' \
  -- get-devices
```

## Subcommands

| Command | Description |
|---|---|
| `get-devices` | List firmware devices (JSON) |
| `get-updates` | Check LVFS for available updates (JSON) |
| `get-history` | Show firmware update history (JSON) |
| `update [--device-id ID]` | Stage firmware + apply container workarounds (JSON) |
| `esp-info` | Show EFI System Partition details (JSON) |
| `help` | Show usage |

All structured output goes to **stdout** as JSON. Progress and diagnostics go to **stderr**.

## Pod Requirements

The container must run with elevated privileges to access host firmware:

```yaml
spec:
  hostPID: true
  containers:
    - name: fwupd
      securityContext:
        privileged: true
      env:
        - name: FWUPD_UEFI_ESP_PATH
          value: /boot/efi
      volumeMounts:
        - { name: sys-firmware, mountPath: /sys/firmware }
        - { name: sys-bus,      mountPath: /sys/bus }
        - { name: sys-class,    mountPath: /sys/class }
        - { name: sys-devices,  mountPath: /sys/devices }
        - { name: dev,          mountPath: /dev }
        - { name: run-udev,     mountPath: /run/udev }
  volumes:
    - { name: sys-firmware, hostPath: { path: /sys/firmware } }
    - { name: sys-bus,      hostPath: { path: /sys/bus } }
    - { name: sys-class,    hostPath: { path: /sys/class } }
    - { name: sys-devices,  hostPath: { path: /sys/devices } }
    - { name: dev,          hostPath: { path: /dev } }
    - { name: run-udev,     hostPath: { path: /run/udev } }
```

## Container Workarounds

fwupd's uefi_capsule plugin has issues when running inside containers:

1. **ESP auto-detection**: The EFI System Partition isn't mounted in containers. The entrypoint discovers the ESP by GPT partition type and mounts it automatically.

2. **EFI variable patching**: fwupd writes zeroed-out HD device path nodes when running in a container. The `update` subcommand patches the fwupd EFI variable with the correct ESP partition geometry.

3. **Boot entry fixing**: fwupd creates broken EFI boot entries in containers. The `update` subcommand deletes the broken entry and recreates it with the correct disk path.

## Tested Hardware

- Dell OptiPlex 7090 (Talos Linux)

## Building

```bash
docker build -t fwupd:dev .
docker run fwupd:dev help
```

## License

MIT
