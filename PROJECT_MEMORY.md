# Project Memory

Last updated: 2026-06-15

## Project Goal

Build an offline, single-USB GPU acceptance toolkit for bare-metal NVIDIA H200 / B300 / GB300 machines with no network, no installed OS, and no management port.

The USB must support:

```text
UEFI boot
offline SOP and templates
fieldiag-first hardware validation
NVIDIA driver / DCGM / Fabric Manager offline installation
official stress-tool source packages
log retention
persistence with NVIDIA driver blocked by default
```

## Current USB State

USB device:

```text
Kingston DataTraveler 3.0
Disk number used during build: 2
Serial observed: EE0AD35159E8
```

Current Windows-visible partitions:

```text
F:\  UBUNTU_BOOT  FAT32  ~8GB
G:\  GPU_DATA     exFAT  ~32GB
```

There is also a third raw partition reserved for Linux persistence:

```text
PERSIST_RAW  unformatted from Windows
Linux first-boot script formats it as ext4 label writable
```

## Boot Behavior

The USB boot menu is customized in:

```text
boot_configs/grub.cfg
boot_configs/loopback.cfg
```

Default boot entry:

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked
```

Default blocked modules:

```text
nvidia
nvidia_drm
nvidia_modeset
nvidia_uvm
nouveau
```

DCGM/pressure mode is available as a separate menu entry:

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```

## Important Decisions

1. `fieldiag` is the primary hardware acceptance standard.
2. DCGM is the primary official system/stress diagnostic.
3. `nvbandwidth`, `nccl-tests`, and CUDA samples are official supplemental tools.
4. Default boot blocks NVIDIA/nouveau drivers to protect `fieldiag` compatibility.
5. Driver/DCGM mode must be selected intentionally when running system-level stress tests.
6. The USB uses Ubuntu Server 24.04.4 LTS, not the newest LTS, for stability and NVIDIA Ubuntu 24.04 package availability.
7. Stress tools are now precompiled (tools/bin/, sm_90+sm_100); their offline CUDA
   runtime + NCCL and a full offline rebuild toolchain ship as noble debs under
   downloads/offline_deb_noble/. Full CUDA math libs (cublas/cufft) are intentionally
   not packaged since the acceptance tools do not need them.

## Downloaded Official Assets

Stored under:

```text
GPU_Offline_Acceptance/downloads/
```

Assets:

```text
iso/ubuntu-24.04.4-live-server-amd64.iso
nvidia/NVIDIA-Linux-x86_64-610.43.02.run
nvidia/datacenter-gpu-manager_3.3.9_amd64.deb
nvidia/datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb
nvidia/nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb
nvidia/cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb
nvidia/cuda-keyring_1.1-1_all.deb
source/nvbandwidth-main.zip
source/nccl-tests-master.zip
source/cuda-samples-master.zip
DOWNLOAD_MANIFEST.txt
```

Ubuntu ISO SHA256 was verified successfully before USB build.

## Precompiled Binaries + Offline deb (added v2.0, 2026-06-15)

Built on a networked Ubuntu host with CUDA 12.8, written to the USB:

```text
tools/bin/                     nvbandwidth, all_reduce_perf & other *_perf,
                               deviceQuery, p2pBandwidthLatencyTest
                               (fatbin: sm_90 H200 + sm_100 B300/GB300)
tools/bin_MANIFEST.sha256      sha256 of the binaries
downloads/offline_deb_noble/runtime/   cuda-cudart-12-8 + libnccl2 2.30.7+cuda12.9
downloads/offline_deb_noble/rebuild/   full offline rebuild toolchain (141 debs:
                               nvcc 12.8, build-essential, cmake, boost, unzip,
                               nccl dev, complete dependency closure)
downloads/offline_deb_noble/README.txt + MANIFEST.sha256
scripts/install_offline_cuda_runtime.sh   installs the runtime debs on target
```

Key version decisions:

```text
nccl-tests needs NCCL >= 2.30 symbols (ncclTeamLsa, ncclDevCommCreate, ...);
shipped libnccl2 is 2.30.7 (the +cuda12.9 build -> single libcudart.so.12).
All CUDA components are the 12.8 line, matching libcudart.so.12 the binaries link.
```

Offline verification (all in a network-disabled ubuntu:24.04 container): binary
symbol resolution, runtime deb install, rebuild toolchain install on bare noble,
and end-to-end offline recompile of nvbandwidth from the USB source — all passed.
Only the GPU driver (libcuda/libnvidia-ml) must be installed on the real target.

## Missing External Asset

The user has `fieldiag`, but it has not been copied into the project yet.

Expected location:

```text
GPU_Offline_Acceptance/tools/fieldiag/
```

The `offline_gpu_acceptance_collect.sh` script expects the default executable at:

```text
tools/fieldiag/fieldiag
```

If the executable name differs, set:

```bash
FIELDIAG_BIN=/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/<actual_binary>
```

## Package Completeness

See:

```text
docs/package_completeness.md
```

Current short status:

```text
Ready: Ubuntu Server LTS boot, NVIDIA driver runfile, DCGM, Fabric Manager, CUDA
  compatibility, official source packages, PRECOMPILED stress binaries (tools/bin/,
  sm_90+sm_100), offline CUDA runtime + NCCL deb, offline full rebuild toolchain.
Missing: fieldiag package (user must copy in). That is now the only hard gap.
```

## First Linux Boot Steps

Boot default fieldiag mode, then mount data:

```bash
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
```

Initialize persistence partition once:

```bash
sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh
```

NOTE: the persistence partition (sda3, ~18 GB) was ALREADY formatted as ext4
label `writable` on 2026-06-16, so this step is normally a no-op — the script
will report "no unformatted persistence partition found", which is expected.
Only re-run it if the partition was wiped.

Reboot into default fieldiag mode again.

## Fieldiag Mode

Default mode should avoid driver interference.

Optional persistent block inside the live system:

```bash
sudo bash scripts/set_fieldiag_driver_block.sh
```

Run collection (one command):

```bash
sudo bash scripts/run_acceptance.sh fieldiag
```

This runs fieldiag, collects logs, skips driver-only tools (DCGM/nvbandwidth),
and writes a pre-filled `final_result.txt` into the timestamped log directory.
The lower-level `scripts/offline_gpu_acceptance_collect.sh` can still be called
directly if finer control is needed.

## DCGM / Stress Mode

Reboot and choose:

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```

Then:

```bash
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo bash scripts/run_acceptance.sh dcgm
```

`run_acceptance.sh dcgm` installs the offline NVIDIA tools, best-effort builds
the stress-tool sources, then collects with DCGM and nvbandwidth enabled and
fieldiag skipped. Use `SKIP_INSTALL=1` / `SKIP_BUILD=1` to skip those stages.

If CUDA build dependencies are available:

```bash
sudo bash scripts/build_official_stress_tools.sh
```

## Key Acceptance Thresholds

H200:

```text
HBM bandwidth PASS:   >= 4.3 TB/s
HBM bandwidth RETEST: >= 4.1 TB/s and < 4.3 TB/s
HBM bandwidth FAIL:   < 4.1 TB/s
```

B300/GB300:

```text
Use OEM official single-GPU bandwidth X.
PASS:   >= X * 90%
RETEST: >= X * 85% and < X * 90%
FAIL:   < X * 85%
```

Hard fail:

```text
fieldiag FAIL
XID
GPU fallen off the bus
uncorrectable ECC
GPU reset
PCIe fatal error
NVLink missing/fatal
performance below fail line
```

## Next Recommended Work

1. Copy the user's `fieldiag` package into `tools/fieldiag/`.
2. Boot one target machine in fieldiag mode.
3. Initialize persistence partition.
4. Confirm default boot blocks NVIDIA/nouveau modules.
5. Run `fieldiag` and collect logs.
6. Reboot into DCGM mode and test offline driver/DCGM installation.
   In dcgm mode also run `scripts/install_offline_cuda_runtime.sh`, then the
   tools/bin binaries run directly (no build needed).
7. DONE: precompiled `nvbandwidth`, `nccl-tests`, `deviceQuery`,
   `p2pBandwidthLatencyTest` in tools/bin/ (sm_90+sm_100); cuda-samples zip added.
8. DONE: `scripts/run_acceptance.sh` added (fieldiag/dcgm one-command modes).
   Set `FIELDIAG_ARGS` once the exact fieldiag arguments for the target SKU are known.
9. DONE: noble offline deb (runtime + full rebuild toolchain) in
   downloads/offline_deb_noble/; offline-install + offline-recompile verified.
