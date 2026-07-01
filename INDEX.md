# GPU Offline Acceptance USB — Index

> **This tree is the lightweight SOURCE copy.** The heavy artifacts (Ubuntu ISO,
> NVIDIA driver/DCGM/FM, noble offline debs, source zips, compiled `tools/bin/`
> binaries — ~5.6 GB) are **not** included here; regenerate them with
> `bash bootstrap.sh` (see `bootstrap/README.md`), then copy the tree onto the USB.
> The USB itself carries the full, ready-to-run set.

One-page map of the whole USB. For background and decisions see `PROJECT_MEMORY.md`;
for the executable step-by-step procedure see `docs/offline_gpu_acceptance_sop.md` (**SOP v2.0** — real commands, two boot modes, precompiled tools).

## USB partitions (single physical disk)

| Partition | Label        | FS    | Size  | Purpose |
|-----------|--------------|-------|-------|---------|
| 1         | UBUNTU_BOOT  | FAT32 | 8 GB  | UEFI bootable Ubuntu Server 24.04.4 live system |
| 2         | GPU_DATA     | exFAT | 32 GB | This project: tools, offline packages, logs |
| 3         | writable     | ext4  | ~18 GB| Live-system persistence (overlay), logs survive reboot |

Boot menu (see `boot_configs/`):
- **fieldiag mode** (default) — persistent, NVIDIA/nouveau drivers blocked.
- **dcgm mode** — persistent, NVIDIA driver allowed (for DCGM / stress tools).

## GPU_DATA/GPU_Offline_Acceptance/ layout

| Path | What |
|------|------|
| `INDEX.md` | This file |
| `START_HERE.txt` | Shortest boot-to-run path |
| `README.md` / `PROJECT_PLAN.md` / `PROJECT_MEMORY.md` | Overview, plan, state & decisions |
| `docs/` | SOP, acceptance criteria, USB design, runbooks, completeness |
| `scripts/` | Helper + orchestration scripts (see below) |
| `tools/bin/` | **Precompiled** stress binaries (sm_90 H200 + sm_100 B300/GB300) |
| `tools/fieldiag/` | **Drop fieldiag here** (only remaining gap — see PLACEHOLDER.txt) |
| `downloads/nvidia/` | Driver / DCGM / Fabric Manager offline debs (target install) |
| `downloads/offline_deb_noble/` | CUDA runtime + NCCL (`runtime/`) and full rebuild toolchain (`rebuild/`) |
| `downloads/iso/`, `downloads/source/` | Re-flash / recompile sources only (not used at acceptance time) |
| `templates/` | Final result + onsite checklist templates |
| `logs/`, `reports/`, `inventory/` | Output collected during acceptance |

See `downloads/README.txt` for the target-vs-rebuild asset split.

## Target machine offline workflow

```text
1. Boot target from UEFI USB.
2. sudo mount -L GPU_DATA /mnt/gpu_acceptance
   cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
3. (once) sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh   # if not pre-formatted

# Hardware-first (fieldiag) — requires tools/fieldiag/fieldiag:
4a. sudo bash scripts/run_acceptance.sh fieldiag

# System / stress (DCGM, nvbandwidth, nccl-tests) — boot dcgm mode:
4b. sudo bash scripts/install_offline_nvidia_tools.sh      # driver + DCGM + FM
    sudo bash scripts/install_offline_cuda_runtime.sh      # CUDA runtime + NCCL
    sudo bash scripts/run_acceptance.sh dcgm               # runs tools/bin binaries
```

Each run writes a timestamped dir under `logs/` plus a pre-filled `final_result.txt`.

## Scripts

| Script | Role |
|--------|------|
| `run_acceptance.sh` | One-command orchestrator: `fieldiag` or `dcgm` mode |
| `offline_gpu_acceptance_collect.sh` | Low-level log/diag collector |
| `mount_gpu_data.sh` | Mount GPU_DATA by label |
| `init_persistence_partition.sh` | Format the persistence partition (ext4 `writable`) |
| `set_fieldiag_driver_block.sh` | Persistently blacklist NVIDIA/nouveau |
| `install_offline_nvidia_tools.sh` | Offline driver / DCGM / Fabric Manager |
| `install_offline_cuda_runtime.sh` | Offline CUDA runtime + NCCL (to run tools/bin) |
| `build_official_stress_tools.sh` | Recompile tools from source (fallback) |
| `prepare_single_usb_minimal.ps1`, `verify_downloads.ps1` | Windows build-host scripts |

## Integrity

- `tools/bin_MANIFEST.sha256` — precompiled binaries
- `downloads/offline_deb_noble/MANIFEST.sha256` — offline debs
- `downloads/DOWNLOAD_MANIFEST.txt` — originally downloaded assets

## Status

Ready: boot, driver/DCGM/FM, CUDA runtime+NCCL, precompiled binaries, offline
rebuild toolchain — all offline-verified. **Only gap: copy fieldiag into
`tools/fieldiag/`.**
