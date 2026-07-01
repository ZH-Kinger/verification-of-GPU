# bootstrap/ — regenerate the heavy artifacts

This is the **lightweight source copy** of the GPU acceptance project. It keeps every
script, doc, template, config and manifest, but omits the large binary payloads that
live on the USB (~5.6 GB): the Ubuntu ISO, NVIDIA driver/DCGM/FM packages, the noble
offline `.deb` bundles, the source zips, and the compiled `tools/bin/` binaries.

Run these on a **networked Linux workshop host** to rebuild those artifacts into the
same relative layout, then copy the tree onto the USB's `GPU_DATA` partition.

```bash
bash bootstrap.sh                 # default: sources + binaries + offline_deb
bash bootstrap.sh all             # also iso + nvidia
bash bootstrap.sh sources         # just one step
```

| Step | Script | Produces | Needs |
|------|--------|----------|-------|
| sources | `10_fetch_sources.sh` | `downloads/source/*.zip` | network |
| binaries | `20_build_binaries.sh` | `tools/bin/*` (sm_90+sm_100) | CUDA toolkit ≥12.8 (nvcc), cmake, libnccl-dev, boost; `RUN_APT=1` to auto-install the non-CUDA deps |
| offline_deb | `30_fetch_offline_deb_noble.sh` | `downloads/offline_deb_noble/{runtime,rebuild}` | docker + network |
| iso | `40_fetch_iso.sh` | `downloads/iso/*.iso` (~3.2 GB) | network |
| nvidia | `50_fetch_nvidia.sh` | `downloads/nvidia/*` | network; driver `.run` via `DRIVER_URL` or manual |

## Notes / gotchas (see ../CLAUDE.md and ../PROJECT_MEMORY.md for the why)

- **Host vs target:** `offline_deb` uses a `ubuntu:24.04` container so the debs match
  the noble target regardless of this host's distro. Do not substitute host `apt`.
- **NCCL pin:** the runtime/rebuild NCCL is `2.30.7+cuda12.9` — needed because
  nccl-tests master calls NCCL ≥2.30 symbols, and the +cuda12.9 build keeps a single
  `libcudart.so.12` across all tools. Changing this can break tools/bin at load time.
- **Binaries build to sm_90+sm_100** by default (`CUDA_ARCH="90;100"`). They run on
  the newer-glibc target even when built on an older host (glibc is backward-compatible).
- **Driver runfile version (610.43.02)** is served from NVIDIA's driver host, not the
  CUDA repo; its URL is not hardcoded. Provide `DRIVER_URL=` or drop the `.run` in.
- Idempotent: existing files are skipped; delete an artifact to force a refetch.
