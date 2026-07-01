downloads/ — what each subdirectory is for
==========================================

Two categories: assets the TARGET machine consumes offline, vs assets only used
to (re)build the USB or recompile tools.

A. For the TARGET acceptance machine (offline install)
------------------------------------------------------
nvidia/              NVIDIA driver runfile + DCGM + Fabric Manager + cuda-compat
                       Install: scripts/install_offline_nvidia_tools.sh (dcgm mode)
offline_deb_noble/   CUDA runtime + NCCL (runtime/) and full offline rebuild
                       toolchain (rebuild/) for Ubuntu 24.04 noble.
                       Install runtime: scripts/install_offline_cuda_runtime.sh
                       (see offline_deb_noble/README.txt)

B. For (re)building the USB or recompiling tools (NOT needed at acceptance time)
-------------------------------------------------------------------------------
iso/                 Ubuntu Server 24.04.4 live ISO (+ SHA256SUMS). Only used to
                       re-flash / rebuild the boot USB. The bootable system itself
                       lives on the UBUNTU_BOOT partition, so the target does not
                       read this ISO. Kept here as the offline re-flash source.
source/              nvbandwidth / nccl-tests / cuda-samples source zips. The
                       binaries are already prebuilt in tools/bin/; these are only
                       needed if you recompile on the target (offline_deb_noble/rebuild/).

DOWNLOAD_MANIFEST.txt  SHA256 of the originally downloaded assets (generated on the
                       Windows build host).

Note: tools/bin binaries run with just the driver + offline_deb_noble/runtime/.
Recompiling from source/ is a fallback, not part of the normal acceptance flow.
