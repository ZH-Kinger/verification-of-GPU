# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Not an application — a **bootable offline GPU acceptance toolkit** that lives on a 3-partition
USB stick. It validates bare-metal NVIDIA H200 / B300 / GB300 machines that have **no network,
no pre-installed OS, and no management port**. There is no build/lint/test suite; the "code" is
bash/PowerShell scripts plus precompiled binaries and offline `.deb` bundles.

`INDEX.md` is the human map of the whole USB. `PROJECT_MEMORY.md` holds state and version
decisions. Read those two before making changes.

## The core mental model: workshop host vs offline target

Two different machines, and confusing them causes real bugs:

- **Workshop host** = a networked Linux box (this project was built on Ubuntu 22.04 *jammy*)
  used only to download and compile. Products are written onto the USB.
- **Target** = the machine under acceptance, which boots the USB's `UBUNTU_BOOT` partition
  (Ubuntu Server 24.04 **noble**) and runs **fully offline**.

Consequence: any `.deb` destined for the target must be a **noble** package, even though the
host is jammy. `apt download` on the host fetches the wrong (jammy) versions. The established
pattern is to resolve/fetch inside a `docker run ubuntu:24.04` container (see `PROJECT_MEMORY.md`
"Precompiled Binaries + Offline deb"). glibc is backward-compatible, so host-compiled binaries
run on the newer-glibc target; but linking a noble `.so` on the jammy host fails.

## USB layout (3 partitions, one physical disk)

| Label | FS | Role |
|-------|----|------|
| UBUNTU_BOOT | FAT32 | UEFI-bootable Ubuntu 24.04.4 live system |
| GPU_DATA | exFAT | this project (`GPU_Offline_Acceptance/`), tools, offline packages, logs |
| writable | ext4 | live-system persistence overlay (already formatted) |

GPU_DATA is **exFAT**: do not compile on it, and treat the exec bit as synthesized by the
mount, not stored. Compile off-USB and copy binaries in.

## Two run modes (selected at grub, orchestrated by one script)

The grub menu (`boot_configs/`) offers **fieldiag mode** (default, NVIDIA/nouveau drivers
blacklisted) and **dcgm mode** (driver allowed). `scripts/run_acceptance.sh` wraps everything:

```bash
sudo bash scripts/run_acceptance.sh fieldiag   # hardware-first; runs tools/fieldiag/fieldiag; skips driver-only tools
sudo bash scripts/run_acceptance.sh dcgm        # installs offline tools, then DCGM + nvbandwidth; skips fieldiag
```

It calls `offline_gpu_acceptance_collect.sh` (the low-level collector that runs each diagnostic,
captures `<name>.txt`/`<name>.exit`, and writes a timestamped `logs/<ts>_<SN>/` with a pre-filled
`final_result.txt`). Env overrides that matter: `FIELDIAG_BIN`, `FIELDIAG_ARGS`,
`EXPECTED_GPU_COUNT/MODEL`, `RUN_DCGM`, `RUN_NVBANDWIDTH`, `SKIP_INSTALL`, `SKIP_BUILD`.

`fieldiag` is the **primary hardware acceptance standard** and is the one hard gap: it is not in
the repo and must be dropped into `tools/fieldiag/` (see that dir's `PLACEHOLDER.txt`). Scripts
record it as missing and continue if absent. Any single GPU failing means the whole machine is
not PASS.

## Target-side install/run order (all offline)

```bash
sudo bash scripts/install_offline_nvidia_tools.sh    # driver runfile + DCGM + Fabric Manager
sudo bash scripts/install_offline_cuda_runtime.sh    # CUDA runtime + NCCL (needed by tools/bin)
# then tools/bin/* run directly, or via run_acceptance.sh dcgm
```

`docs/first_target_run_checklist.md` is the step-by-step first-run runbook with STOP conditions.

## Precompiled binaries and their runtime deps

`tools/bin/` holds fatbins for **sm_90 (H200) + sm_100 (B300/GB300)**: `nvbandwidth`, the
nccl-tests `*_perf` set, `deviceQuery`, `p2pBandwidthLatencyTest`. Runtime needs:

- `nvbandwidth`: GPU driver only (libcuda / libnvidia-ml)
- nccl-tests: driver + `libcudart.so.12` + `libnccl.so.2` (>= 2.30)
- deviceQuery / p2p: driver + `libcudart.so.12`

Non-obvious version pin: nccl-tests master calls NCCL symbols (`ncclTeamLsa`, `ncclDevCommCreate`)
that exist only in **NCCL >= 2.30**, so the shipped `libnccl2` is **2.30.7, the +cuda12.9 build**
— chosen so the whole stack stays on a single `libcudart.so.12`. All CUDA components are the 12.8
line. Do not "upgrade" the NCCL deb to a cuda13 build without re-checking cudart consistency.

## Rebuilding tools from source (fallback, offline-capable)

`downloads/offline_deb_noble/rebuild/` is a **complete dependency closure** (nvcc 12.8,
build-essential, cmake, boost, unzip, nccl dev) that `dpkg -i`'s cleanly on a bare noble target
with no network. Then:

```bash
sudo bash scripts/build_official_stress_tools.sh     # CUDA_ARCH="90;100" by default; honors CUDA_HOME/NCCL_HOME
```

Gotchas this script already handles: nvbandwidth and cuda-samples are **CMake**-based (new
cuda-samples uses a `cpp/` layout and dropped `bandwidthTest`); some sample `CMakeLists.txt`
hardcode an architecture list containing `sm_110`, which CUDA 12.8 rejects — it is `sed`-patched
to `CUDA_ARCH`. nccl-tests is `make MPI=0` with `NVCC_GENCODE`.

## Working on this repo

- Validate script edits with `bash -n scripts/*.sh` (no runtime here can exercise them).
- Scripts self-locate `BASE_DIR` relative to `scripts/`; keep them runnable from any cwd and do
  not move files between `downloads/` subdirs without updating script paths.
- Integrity manifests: `tools/bin_MANIFEST.sha256`, `downloads/offline_deb_noble/MANIFEST.sha256`,
  `downloads/DOWNLOAD_MANIFEST.txt`. Regenerate after changing the corresponding artifacts.
- Editing note: `docs/package_completeness.md` contains one corrupted UTF-8 byte inside an
  obsolete "(旧) CUDA Toolkit" subsection; edit around it rather than trying to match that line.
- Docs are bilingual (Chinese prose + English code/paths); match the surrounding language of the
  file you edit.
