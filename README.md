# Offline GPU Acceptance Toolkit

A bootable, **fully offline** acceptance toolkit for bare-metal NVIDIA
**H200 / B300 / GB300** servers that have no network, no pre-installed OS, and no
management port. It ships an SOP, pass/fail criteria, field templates, helper
scripts, precompiled stress binaries, and offline install packages on a single USB.

## Acceptance standard

A machine is **PASS** only if all of the following hold — any single GPU failing
means the whole machine is not PASS:

```text
Official/OEM fieldiag PASS
+ no hard hardware errors (XID / GPU off the bus / uncorrectable ECC / PCIe·NVLink fatal / reset)
+ minimum stress/performance thresholds reached
+ complete offline logs retained (traceable to server SN and GPU SN)
```

`fieldiag` is the primary hardware diagnostic. DCGM, bandwidth, topology, and NCCL
tests are system-integration and performance evidence.

## This repo vs the USB

- **The git repo** is the lightweight *source* (scripts, docs, configs — a few hundred KB).
- **The USB** carries the *full* ready-to-run set including ~5.6 GB of binaries and
  offline `.deb` packages, which are **git-ignored** here and regenerated with
  [`bootstrap.sh`](bootstrap.sh) (see [`bootstrap/README.md`](bootstrap/README.md)).

## Quick start (on the offline target machine)

The USB boots into a grub menu with two modes. Full procedure:
[`docs/offline_gpu_acceptance_sop.md`](docs/offline_gpu_acceptance_sop.md).

```bash
# Mount the data partition after booting from USB
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance

# A) fieldiag mode (default grub entry, drivers blocked) — hardware acceptance
sudo bash scripts/run_acceptance.sh fieldiag        # needs tools/fieldiag/fieldiag

# B) dcgm mode (reboot, driver allowed) — system / stress / performance
sudo bash scripts/install_offline_nvidia_tools.sh   # driver + DCGM + Fabric Manager
sudo bash scripts/install_offline_cuda_runtime.sh   # CUDA runtime + NCCL
sudo bash scripts/run_acceptance.sh dcgm            # DCGM + nvbandwidth + collection
```

Each run writes `logs/<timestamp>_<SN>/` with raw logs and a pre-filled `final_result.txt`.

> **One prerequisite gap:** the official/OEM `fieldiag` is not included — copy it into
> `tools/fieldiag/` (see that dir's `PLACEHOLDER.txt`).

## Layout

Start with [`INDEX.md`](INDEX.md) (whole-USB map) and [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md)
(state & decisions).

| Area | Contents |
|------|----------|
| **docs/** | `offline_gpu_acceptance_sop.md` (SOP v2.0, executable) · `acceptance_criteria.md` (thresholds) · `first_target_run_checklist.md` (first-run debugging) · USB design, runbooks, persistence, completeness notes |
| **scripts/** | `run_acceptance.sh` (one-command orchestrator) · `install_offline_nvidia_tools.sh` · `install_offline_cuda_runtime.sh` · `offline_gpu_acceptance_collect.sh` · `build_official_stress_tools.sh` · `init_persistence_partition.sh` · `set_fieldiag_driver_block.sh` · `mount_gpu_data.sh` · `*.ps1` (Windows USB-build helpers) |
| **tools/bin/** | Precompiled stress binaries (sm_90 H200 + sm_100 B300/GB300): `nvbandwidth`, nccl-tests `*_perf`, `deviceQuery`, `p2pBandwidthLatencyTest` |
| **tools/fieldiag/** | Drop point for `fieldiag` (the one gap) |
| **downloads/** | Target-side offline installs: `nvidia/` (driver/DCGM/FM), `offline_deb_noble/` (`runtime/` to run binaries, `rebuild/` full offline recompile toolchain). Rebuild-only: `iso/`, `source/` |
| **templates/** | `final_result_template.txt`, `machine_acceptance_checklist.csv` |
| **boot_configs/** | `grub.cfg`, `loopback.cfg` (the two boot modes) |

## Rebuilding the heavy artifacts

Run on a networked Linux host, then copy the tree onto the USB's `GPU_DATA` partition:

```bash
bash bootstrap.sh              # sources + compiled binaries + offline noble debs
bash bootstrap.sh all          # also the Ubuntu ISO and NVIDIA driver/DCGM/FM
```

## Documentation map

| Read this | For |
|-----------|-----|
| [`INDEX.md`](INDEX.md) | One-page map of the whole USB and workflow |
| [`docs/offline_gpu_acceptance_sop.md`](docs/offline_gpu_acceptance_sop.md) | **How to run acceptance** (SOP v2.0) |
| [`docs/acceptance_criteria.md`](docs/acceptance_criteria.md) | Pass / retest / fail thresholds |
| [`docs/first_target_run_checklist.md`](docs/first_target_run_checklist.md) | First end-to-end run on real hardware, with STOP conditions |
| [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) | Project state, decisions, version pins |
| [`CLAUDE.md`](CLAUDE.md) | Architecture & gotchas for future contributors |
