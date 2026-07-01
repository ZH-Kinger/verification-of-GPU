# Offline GPU Acceptance Project

This project contains the offline acceptance SOP, minimum pass criteria, field templates, and helper script for bare-metal NVIDIA H200 / B300 / GB300 GPU inspection.

## Deliverables

- `docs/offline_gpu_acceptance_sop.md`: offline single-machine acceptance SOP — **v2.0, executable**: real per-machine commands, the two boot modes (fieldiag / dcgm), and the precompiled `tools/bin` binaries. Thresholds live in `acceptance_criteria.md`; first-run debugging in `first_target_run_checklist.md`.
- `docs/acceptance_criteria.md`: pass, retest, fail criteria and performance thresholds.
- `docs/single_usb_boot_disk_design.md`: single USB boot disk partition and directory design.
- `docs/minimal_usb_build_runbook.md`: Ubuntu Server LTS minimal boot USB build runbook.
- `docs/stress_tools_inventory.md`: downloaded stress/diagnostic tool inventory and usage notes.
- `docs/persistence_options.md`: persistence options, tradeoffs, and recommended route.
- `docs/linux_migration_notes.md`: handoff notes for continuing development on Linux.
- `docs/package_completeness.md`: current package completeness, missing items, and next steps.
- `docs/first_target_run_checklist.md`: step-by-step checklist for the first end-to-end run on a real H200/B300/GB300 machine, with expected results and stop conditions.
- `PROJECT_MEMORY.md`: project state, decisions, current USB layout, and next steps.
- `templates/final_result_template.txt`: final machine acceptance record.
- `templates/machine_acceptance_checklist.csv`: onsite checklist template.
- `scripts/run_acceptance.sh`: one-command Linux orchestrator that wraps the helper scripts into a `fieldiag` or `dcgm` acceptance run and writes a pre-filled final result into the log directory.
- `scripts/offline_gpu_acceptance_collect.sh`: Linux USB helper script for collecting logs and running available diagnostics.
- `scripts/mount_gpu_data.sh`: Linux helper script for mounting the `GPU_DATA` partition by label.
- `scripts/prepare_single_usb_minimal.ps1`: Windows PowerShell script to repartition a USB disk and build a minimal Ubuntu Server boot USB with a GPU data partition.
- `scripts/verify_downloads.ps1`: Windows PowerShell script to generate SHA256 download manifest and verify the Ubuntu LTS ISO checksum.
- `scripts/install_offline_nvidia_tools.sh`: Linux helper script for installing offline NVIDIA driver/DCGM/Fabric Manager packages when the diagnostic environment supports it.
- `scripts/install_offline_cuda_runtime.sh`: Linux helper script for installing the offline CUDA runtime + NCCL (downloads/offline_deb_noble/runtime/) needed to run the precompiled binaries in `tools/bin/`.
- `tools/bin/`: precompiled stress binaries for sm_90 (H200) + sm_100 (B300/GB300) — nvbandwidth, nccl-tests `*_perf`, deviceQuery, p2pBandwidthLatencyTest.
- `downloads/offline_deb_noble/`: offline .deb packages for the Ubuntu 24.04 target — `runtime/` (run the binaries) and `rebuild/` (full offline recompile toolchain).
- `scripts/build_official_stress_tools.sh`: Linux helper script that builds downloaded NVIDIA official stress-tool sources when CUDA and compiler dependencies are available.
- `scripts/init_persistence_partition.sh`: Linux helper script to format the raw persistence partition as ext4 label `writable`.
- `scripts/set_fieldiag_driver_block.sh`: Linux helper script to persistently block NVIDIA/nouveau driver loading for fieldiag mode.

## Project Positioning

The acceptance standard is:

```text
Official/OEM fieldiag PASS
+ no hard hardware errors
+ minimum stress/performance thresholds reached
+ complete offline logs retained
```

`fieldiag` is treated as the primary hardware diagnostic. DCGM, bandwidth, topology, and workload tests are treated as system integration and performance evidence.
