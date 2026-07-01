#!/usr/bin/env bash
set -u

LABEL="${LABEL:-GPU_DATA}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/gpu_acceptance}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash scripts/mount_gpu_data.sh"
  exit 1
fi

device="$(blkid -L "$LABEL" 2>/dev/null || true)"

if [ -z "$device" ]; then
  echo "Unable to find partition with label: $LABEL"
  echo
  echo "Available block devices:"
  lsblk -f
  exit 1
fi

mkdir -p "$MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
  echo "$MOUNT_POINT is already mounted."
else
  mount "$device" "$MOUNT_POINT"
fi

echo "Mounted $device at $MOUNT_POINT"
echo
echo "Next:"
echo "cd $MOUNT_POINT/GPU_Offline_Acceptance"
echo "bash scripts/offline_gpu_acceptance_collect.sh"

