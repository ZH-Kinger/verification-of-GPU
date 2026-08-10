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

## Two acceptance tracks, two grub modes

Since v3.0 the project serves **two acceptance chains** that share one threshold system:

- **单机离线压测** (single-node, offline, USB) — 《验收标准》§1 §2 §3 §4 §7 §8.
  `scripts/preflight.sh` → `collect_node.sh` → `check_node.sh`, plus `soak_node.sh` for §8.
- **多机压测** (multi-node, needs network + MPI + passwordless SSH) — §5 §6.
  `scripts/cluster/{roce_check,nccl_scale,check_cluster}.sh`. Does **not** run on the
  live USB; the nodes use their own OS. See `docs/cluster_runbook.md`.

**All numeric thresholds live in `profiles/<name>.env`** — GPU count, memory, TDP,
bandwidth floors, temperature, *and* the per-model driver/CUDA/NCCL/DCGM version
requirements plus which `tools/<subdir>` binary set to use. Different GPU models need
different CUDA lines; never hardcode a version or a threshold in a script. Adding a
model = adding one profile file.

Every threshold carries a source tag: `[标准]` (verbatim from the customer document —
do not change), `[推导]` (derived, with the derivation written out), `[待校准]`
(placeholder pending first-batch measurements). A derived threshold must state what it
is meant to catch — e.g. the system-memory floor sits at 3000 GiB because a full
24×128GiB config reports ~3047 GiB after kernel reserve while one missing DIMM is
2944 GiB; the earlier guess of 2900 would have passed a machine with a dead DIMM.

The grub menu (`boot_configs/`) still offers **fieldiag mode** (default, NVIDIA/nouveau
blacklisted) and **dcgm mode** (driver allowed). fieldiag remains the stage-1 hardware
standard; the 《验收标准》 table is stage 2 and needs the driver, so it runs in dcgm mode.

```bash
sudo bash scripts/run_acceptance.sh fieldiag              # 阶段一：hardware-first, driver blocked
sudo bash scripts/run_acceptance.sh standard b300_8gpu    # 阶段二：preflight + collect + auto-verdict
sudo bash scripts/run_acceptance.sh soak <log_dir>        # §8 long soak, then re-verdict
sudo bash scripts/run_acceptance.sh dcgm                  # legacy v1.0 collection path
```

`check_node.sh` emits `acceptance_report.tsv`/`.txt` plus `per_gpu_detail.tsv`.
The report columns mirror the customer's own table (章节/模块/测试项/测试手段·命令)
and add 实测值/余量/判定. **Measured values must always be concrete numbers, never
yes/no** — `8/8 Enabled`, `56/56 个 GPU 对为 NV18`, `12 个，转速 8000~8600 RPM` — because
the report is the acceptance evidence. 余量 is the percentage headroom against the
threshold, which is what distinguishes a comfortable pass from one scraping the line.
Verdicts are PASS / FAIL / SKIP / MANUAL; any FAIL → machine FAIL, no FAIL but any
SKIP → **HOLD** (a missing tool must never read as a pass).

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

## Known conflicts with the customer standard (do not "fix" silently)

- **CUDA ≥ 13.0 vs the shipped 12.8 line.** Blackwell Ultra is expected to be `sm_103`,
  which CUDA 12.8 cannot target; sm_100 cubins will not load on it. Decision on record:
  ship the scripts first, confirm the real compute capability with `preflight.sh` on a
  target, then rebuild. Full plan in `docs/cuda_arch_decision.md`.
- **DCGM 3.3.9 does not support Blackwell.** `b300_8gpu.env` requires ≥ 4.0. The checker
  treats "JSON has no Pass records" as FAIL, not as a silent pass.
- **§8 says 24h in the title but `-tc 64800` (18h) in the command**, and the §3 ECC row
  also says 18h. Profile follows the command; confirm with the customer before signing.
- **fieldiag is absent from the customer standard** but is still stage 1 here.

## Working on this repo

- **Run `bash tests/run_parser_tests.sh` after any change to `check_node.sh`,
  `check_cluster.sh`, `lib/common.sh`, or a profile.** No GPU or network required.
  It syntax-checks every script, replays synthetic "fully compliant" single-node and
  cluster fixtures, then applies ~28 targeted degradations asserting each threshold
  actually bites, and finally (only if `nvidia-smi` exists) validates every
  `--query-gpu` field name against the real driver and checks the soak harness leaves
  no stray background processes. Add a degradation case when you add a standard item.
- Every bug found in this codebase so far was invisible to `bash -n` and only surfaced
  by running the parsers on realistic output: `ipmitool`'s status is column 4 not 3;
  `grep -c` with multiple files prints one count *per file* even with `-h`; `num_min`
  renders `1` or `1.00` depending on the value so its output must never be string-compared;
  `nvidia-smi` returning `[N/A]` became `0` and produced a false PASS; GNU `timeout`
  puts its child in a *new* process group so killing the job's group misses it.
  Treat "it looks right" as unverified.
- Scripts self-locate `BASE_DIR` relative to `scripts/`; keep them runnable from any cwd and do
  not move files between `downloads/` subdirs without updating script paths.
- Integrity manifests: `tools/bin_MANIFEST.sha256`, `downloads/offline_deb_noble/MANIFEST.sha256`,
  `downloads/DOWNLOAD_MANIFEST.txt`. Regenerate after changing the corresponding artifacts.
- Editing note: `docs/package_completeness.md` contains one corrupted UTF-8 byte inside an
  obsolete "(旧) CUDA Toolkit" subsection; edit around it rather than trying to match that line.
- Docs are bilingual (Chinese prose + English code/paths); match the surrounding language of the
  file you edit.
