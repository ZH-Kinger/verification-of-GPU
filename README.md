# Offline GPU Acceptance Toolkit

A bootable, **fully offline** toolkit for accepting bare-metal NVIDIA
**H200 / B300 / GB300** servers that have no network, no OS, and no management port.
Everything an on-site operator needs — SOP, pass/fail criteria, diagnostics, and
offline install packages — ships on a single USB stick.

## Quick start

Boot the target from the USB (UEFI), then:

```bash
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance

# A) fieldiag mode  (default grub entry, GPU drivers blocked) — hardware acceptance
sudo bash scripts/run_acceptance.sh fieldiag

# B) dcgm mode      (reboot into this entry, driver allowed) — system / stress / performance
sudo bash scripts/install_offline_nvidia_tools.sh    # driver + DCGM + Fabric Manager
sudo bash scripts/install_offline_cuda_runtime.sh    # CUDA runtime + NCCL
sudo bash scripts/run_acceptance.sh dcgm
```

Each run saves `logs/<timestamp>_<SN>/` with raw logs and a pre-filled `final_result.txt`.
Full procedure and stop conditions: [`docs/offline_gpu_acceptance_sop.md`](docs/offline_gpu_acceptance_sop.md).

> **One prerequisite:** the official/OEM `fieldiag` is not bundled — drop it into
> `tools/fieldiag/` before running fieldiag mode (see that dir's `PLACEHOLDER.txt`).

## How it works

The USB has three partitions — `UBUNTU_BOOT` (bootable Ubuntu 24.04 live),
`GPU_DATA` (this project + tools + logs), `writable` (persistence) — and boots into a
grub menu with two modes:

- **fieldiag mode** (default): NVIDIA/nouveau drivers blocked, for the vendor hardware
  diagnostic. `fieldiag` is the **primary** acceptance standard.
- **dcgm mode**: driver loaded, for DCGM diagnostics and bandwidth/NCCL performance.

A machine is **PASS** only if every one of these holds (any single GPU failing fails
the whole machine):

```text
Official/OEM fieldiag PASS
+ no hard hardware errors (XID / GPU off the bus / uncorrectable ECC / PCIe·NVLink fatal / reset)
+ minimum stress/performance thresholds reached
+ complete offline logs retained (traceable to server SN and GPU SN)
```

## Repository layout

| Path | What it holds |
|------|---------------|
| `docs/` | SOP, pass/fail thresholds, first-run checklist, USB design & runbooks |
| `scripts/` | `run_acceptance.sh` (orchestrator) and the install / collect / build helpers |
| `tools/bin/` | Precompiled stress binaries (sm_90 H200 + sm_100 B300/GB300): `nvbandwidth`, nccl-tests `*_perf`, `deviceQuery`, `p2pBandwidthLatencyTest` |
| `tools/fieldiag/` | Drop point for the OEM `fieldiag` (the one missing piece) |
| `downloads/` | Offline install packages: `nvidia/` (driver/DCGM/FM), `offline_deb_noble/` (CUDA runtime + rebuild toolchain). Re-flash sources: `iso/`, `source/` |
| `templates/` | Final-result and onsite-checklist templates |
| `boot_configs/` | `grub.cfg` / `loopback.cfg` — the two boot modes |
| `bootstrap/` | Scripts that regenerate the heavy artifacts (see below) |

## Rebuild (bootstrap)

- **The git repo** is the lightweight *source* (scripts + docs, a few hundred KB).
- **The USB** additionally carries ~5.6 GB of binaries and offline `.deb` packages,
  which are git-ignored and reproduced from scratch on a networked Linux host:

```bash
bash bootstrap.sh          # source zips + compiled binaries + offline noble debs
bash bootstrap.sh all      # also the Ubuntu ISO and NVIDIA driver/DCGM/FM
```

Then copy the tree onto the USB's `GPU_DATA` partition. Details: [`bootstrap/README.md`](bootstrap/README.md).

## Docs to read next

- [`docs/offline_gpu_acceptance_sop.md`](docs/offline_gpu_acceptance_sop.md) — **how to run acceptance** (SOP v2.0)
- [`docs/acceptance_criteria.md`](docs/acceptance_criteria.md) — pass / retest / fail thresholds
- [`docs/first_target_run_checklist.md`](docs/first_target_run_checklist.md) — first run on real hardware, with STOP conditions
- [`INDEX.md`](INDEX.md) — one-page map of the whole USB · [`PROJECT_MEMORY.md`](PROJECT_MEMORY.md) — state & decisions
