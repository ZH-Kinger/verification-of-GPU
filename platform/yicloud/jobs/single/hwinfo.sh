#!/bin/bash
# 只读硬件清单（容器内能拿到的部分）。输出 key=value，便于两台对比。
r() { cat "$1" 2>/dev/null | tr -d '\n' | sed 's/[[:space:]]*$//'; }
echo "整机厂商=$(r /sys/class/dmi/id/sys_vendor)"
echo "整机型号=$(r /sys/class/dmi/id/product_name)"
echo "整机SN=$(r /sys/class/dmi/id/product_serial)"
echo "主板=$(r /sys/class/dmi/id/board_vendor) $(r /sys/class/dmi/id/board_name)"
echo "主板SN=$(r /sys/class/dmi/id/board_serial)"
echo "BIOS=$(r /sys/class/dmi/id/bios_vendor) $(r /sys/class/dmi/id/bios_version) ($(r /sys/class/dmi/id/bios_date))"
echo "CPU型号=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p')"
echo "CPU路数×核×线程=$(lscpu | sed -n 's/^Socket(s):[[:space:]]*//p')×$(lscpu | sed -n 's/^Core(s) per socket:[[:space:]]*//p')×$(lscpu | sed -n 's/^Thread(s) per core:[[:space:]]*//p')"
echo "CPU微码=$(grep -m1 microcode /proc/cpuinfo | awk '{print $3}')"
echo "内存总量=$(awk '/MemTotal/{printf "%.0f GiB", $2/1048576}' /proc/meminfo)"
echo "内核=$(uname -r)"
echo "GPU型号=$(nvidia-smi --query-gpu=name --format=csv,noheader | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')"
echo "GPU显存=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | sort -u | tr '\n' ';')"
echo "GPU_VBIOS=$(nvidia-smi --query-gpu=vbios_version --format=csv,noheader | sort -u | tr '\n' ';')"
echo "GPU驱动=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | sort -u)"
echo "GPU_SN=$(nvidia-smi --query-gpu=serial --format=csv,noheader | tr '\n' ' ')"
echo "GPU板卡PN=$(nvidia-smi -q | sed -n 's/^ *Board Part Number *: //p' | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')"
echo "GPU_InfoROM=$(nvidia-smi -q | sed -n 's/^ *Image Version *: //p' | sort -u | tr '\n' ';')"
echo "NVSwitch=$(lspci -d 10de:22a3 2>/dev/null | wc -l) 颗 ($(lspci -nn -d 10de:22a3 2>/dev/null | head -1 | sed 's/^[^ ]* //'))"
echo "网卡=$(lspci -nn | grep -i -E 'ethernet|infiniband' | sed -E 's/^[0-9a-f:.]+ //' | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')"
for d in $(lspci -d 15b3: 2>/dev/null | awk '{print $1}' | head -1); do
  echo "网卡PN=$(lspci -vvv -s $d 2>/dev/null | sed -n 's/.*\[PN\] Part number: //p')"
  echo "网卡链路=$(lspci -vvv -s $d 2>/dev/null | sed -n 's/.*LnkSta:[[:space:]]*//p' | head -1)"
done
echo "网卡PN分布=$(for d in $(lspci -d 15b3: 2>/dev/null | awk '{print $1}'); do lspci -vvv -s $d 2>/dev/null | sed -n 's/.*\[PN\] Part number: //p'; done | sort | uniq -c | sed 's/^ *//' | tr '\n' ';')"
for n in /sys/class/nvme/nvme*; do
  echo "NVMe_$(basename $n)=$(r $n/model) | FW $(r $n/firmware_rev) | SN $(r $n/serial) | $(lsblk -dn -o SIZE /dev/$(basename $n)n1 2>/dev/null)"
done
echo "容器CPU限额=$(awk '{printf "%.0f 核", $1/100000}' /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)"
echo "容器内存限额=$(awk '{printf "%.0f GiB", $1/1073741824}' /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
