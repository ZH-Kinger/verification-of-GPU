Offline deb packages for Ubuntu 24.04 (noble) target
=====================================================

These .deb packages are for the TARGET acceptance machine (Ubuntu Server
24.04.4, noble), NOT for the build host. They are fetched online once (here)
and consumed offline on the target.

Layout
------
runtime/   Minimum to RUN the precompiled binaries in tools/bin/.
             - cuda-cudart-12-8        -> libcudart.so.12 (nccl-tests, deviceQuery, p2p)
             - libnccl2 2.30.7+cuda12.9 -> libnccl.so.2    (nccl-tests)
             - cuda-toolkit-*-config-common (dependencies)
           Install with: sudo bash scripts/install_offline_cuda_runtime.sh

rebuild/   Full toolchain to RE-COMPILE the tools on the target if ever needed
           (nvcc 12.8, cudart-dev, nvml-dev, nvrtc-dev, build-essential, cmake,
            libboost-program-options-dev, libnccl2/libnccl-dev 2.30.7+cuda12.9)
           plus the complete recursive dependency closure, so it installs on a
           bare noble system with no network. Install with:
             sudo dpkg -i rebuild/*.deb   (or: sudo apt-get install ./rebuild/*.deb)

Prerequisite: the NVIDIA driver
-------------------------------
None of these packages install the GPU driver. Install the driver FIRST
(scripts/install_offline_nvidia_tools.sh or the runfile in downloads/nvidia/),
because the driver provides libcuda.so.1 and libnvidia-ml.so.1. nvbandwidth
needs only the driver; nccl-tests and the CUDA samples also need runtime/.

Version notes
-------------
- The precompiled nccl-tests binaries were built against NCCL 2.30.7 and require
  symbols (ncclTeamLsa, ncclDevCommCreate, ...) that exist only in NCCL >= 2.30.
  That is why runtime/ ships libnccl2 2.30.7 (the +cuda12.9 build, which keeps a
  single CUDA 12 runtime, libcudart.so.12, across all tools).
- All CUDA components are the 12.8 line to match the build host toolchain and the
  libcudart.so.12 the binaries link against.

Verified
--------
Offline install + dynamic-symbol resolution of all tools/bin binaries was
verified in a clean ubuntu:24.04 container with networking disabled; the only
unresolved libraries are the GPU-driver-provided libcuda.so.1 / libnvidia-ml.so.1.
