#!/usr/bin/env bash
set -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash scripts/set_fieldiag_driver_block.sh"
  exit 1
fi

cat >/etc/modprobe.d/gpu-acceptance-blacklist.conf <<'EOF'
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidia_uvm
options nouveau modeset=0
EOF

systemctl disable --now nvidia-fabricmanager 2>/dev/null || true
systemctl disable --now nvidia-dcgm 2>/dev/null || true
systemctl disable --now nvidia-persistenced 2>/dev/null || true

modprobe -r nvidia_uvm 2>/dev/null || true
modprobe -r nvidia_drm 2>/dev/null || true
modprobe -r nvidia_modeset 2>/dev/null || true
modprobe -r nvidia 2>/dev/null || true
modprobe -r nouveau 2>/dev/null || true

echo "Driver block configuration written to /etc/modprobe.d/gpu-acceptance-blacklist.conf"
echo "For a clean fieldiag run, reboot into:"
echo "  GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked"

