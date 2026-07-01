#!/usr/bin/env bash
# Reconstruct the heavy USB artifacts (ISO, NVIDIA packages, offline noble debs,
# compiled stress binaries) that this lightweight source copy intentionally omits.
# Run on a NETWORKED Linux "workshop" host, then copy the tree onto the USB.
#
# Usage:
#   bash bootstrap.sh [step ...]
# Steps (default: sources binaries offline_deb):
#   sources      -> bootstrap/10_fetch_sources.sh          (GitHub source zips)
#   binaries     -> bootstrap/20_build_binaries.sh         (compile tools/bin, sm_90+sm_100)
#   offline_deb  -> bootstrap/30_fetch_offline_deb_noble.sh (docker noble deb closure)
#   iso          -> bootstrap/40_fetch_iso.sh              (~3.2 GB Ubuntu ISO)
#   nvidia       -> bootstrap/50_fetch_nvidia.sh           (driver/DCGM/FM)
#   all          -> every step above
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

steps=("$@")
[ "${#steps[@]}" -eq 0 ] && steps=(sources binaries offline_deb)
[ "${steps[0]:-}" = "all" ] && steps=(sources binaries offline_deb iso nvidia)

run() { echo; echo "==== $1 ===="; bash "$ROOT/bootstrap/$2"; }

for s in "${steps[@]}"; do
  case "$s" in
    sources)     run sources     10_fetch_sources.sh ;;
    binaries)    run binaries    20_build_binaries.sh ;;
    offline_deb) run offline_deb 30_fetch_offline_deb_noble.sh ;;
    iso)         run iso         40_fetch_iso.sh ;;
    nvidia)      run nvidia      50_fetch_nvidia.sh ;;
    *) echo "unknown step: $s"; exit 2 ;;
  esac
done

echo; echo "Bootstrap done. Review sizes, then rsync the tree onto the USB GPU_DATA partition."
