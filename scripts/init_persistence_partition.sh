#!/usr/bin/env bash
set -u

MOUNT_POINT="${MOUNT_POINT:-/mnt/gpu_acceptance}"
LABEL="${LABEL:-writable}"
MIN_SIZE_GB="${MIN_SIZE_GB:-8}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash scripts/init_persistence_partition.sh"
  exit 1
fi

if ! command -v lsblk >/dev/null 2>&1 || ! command -v mkfs.ext4 >/dev/null 2>&1; then
  echo "Missing lsblk or mkfs.ext4. Cannot initialize persistence partition."
  exit 1
fi

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "$MOUNT_POINT is not mounted."
  echo "First run:"
  echo "  sudo mkdir -p $MOUNT_POINT"
  echo "  sudo mount -L GPU_DATA $MOUNT_POINT"
  exit 1
fi

data_source="$(findmnt -no SOURCE "$MOUNT_POINT" 2>/dev/null || true)"
if [ -z "$data_source" ]; then
  echo "Unable to identify GPU_DATA source device."
  exit 1
fi

data_pkname="$(lsblk -no PKNAME "$data_source" 2>/dev/null | head -n 1)"
if [ -z "$data_pkname" ]; then
  echo "Unable to identify parent disk for $data_source"
  exit 1
fi

disk="/dev/$data_pkname"
echo "GPU_DATA source: $data_source"
echo "Parent disk: $disk"
echo
echo "Candidate empty partitions on $disk:"

mapfile -t candidates < <(
  lsblk -b -nrpo NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT "$disk" |
    awk -v min="$((MIN_SIZE_GB * 1024 * 1024 * 1024))" '$2=="part" && $3=="" && $4>=min && $5=="" {print $1}'
)

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "No unformatted persistence partition found."
  echo "Expected: an unformatted partition >= ${MIN_SIZE_GB}GB on the same USB disk."
  lsblk -f "$disk"
  exit 1
fi

target="${candidates[0]}"
echo "Selected persistence partition: $target"
echo
echo "WARNING: This will format $target as ext4 with label '$LABEL'."
echo "This destroys any data on $target."
echo

if [ "${CONFIRM_FORMAT:-}" != "YES" ]; then
  echo "To continue, run:"
  echo "  sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh"
  exit 1
fi

mkfs.ext4 -F -L "$LABEL" "$target"
sync

echo
echo "Persistence partition initialized:"
lsblk -f "$disk"
echo
echo "Next step: reboot and choose the default grub entry:"
echo "  GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked"

