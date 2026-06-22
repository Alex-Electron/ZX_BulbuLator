#!/bin/sh
# get_deps.sh - fetch the external HDL dependencies the research steps build on.
#
# The repo keeps only our own sources per step (board glue + constraints + build
# scripts). The two FPGA cores and the Digilent IP they need are large and shared
# across many steps, so we do NOT vendor them into git - we fetch them here, pinned
# to exact commits, into ./cores/ and ./deps/ (both git-ignored).
#
# This does NOT install Vivado/Vitis - those are assumed already installed (see
# research/00-setup for versions and what each tool is for). This only clones HDL.
#
# Run once from the repo root, then assemble any step:
#     ./get_deps.sh
#     cd research/06-zx-spectrum-128/sources && ./assemble.sh
#
# Re-running is safe (idempotent): it re-fetches and re-checks-out the pinned commit.
set -eu

ROOT=$(cd "$(dirname "$0")" && pwd)
CORES="$ROOT/cores"
DEPS="$ROOT/deps"
mkdir -p "$CORES" "$DEPS"

# --- pinned commits ----------------------------------------------------------
# Atlas ZX core, our fork. Branch ebaz4205-vivado carries the T80 ALU-mask fix
# (needed under Vivado's strict VHDL) plus the ARM control-plane hooks on
# main/cpu/memory that Steps 7-9 drive over AXI (Step 6 leaves them unconnected).
ZX_URL=https://github.com/Alex-Electron/zx.git
ZX_SHA=407b653e5f7f1fe5cd02340491ed071575754951
# hdl-util/hdmi, our fork (the same TMDS+audio core Steps 3-5 use).
HDMI_URL=https://github.com/Alex-Electron/hdmi.git
HDMI_SHA=fbade3d11a58b885a6084ec75eae25339623355d
# Digilent vivado-library - only Steps 3/4 need it (the rgb2dvi IP for their HDMI BD).
VLIB_URL=https://github.com/Digilent/vivado-library.git
VLIB_SHA=f4613fff005b098065fd5d619a2b88e55720a423
VLIB_SUB=ip/rgb2dvi
# -----------------------------------------------------------------------------

# Clone-or-fetch a small repo and detach onto the pinned commit (fetches all
# branches, so a commit on a non-default branch is reachable).
clone_pinned() {
  url=$1; dir=$2; sha=$3
  if [ -d "$CORES/$dir/.git" ]; then
    git -C "$CORES/$dir" fetch --quiet --all
  else
    git clone --quiet "$url" "$CORES/$dir"
  fi
  git -C "$CORES/$dir" -c advice.detachedHead=false checkout --quiet "$sha"
  echo "  cores/$dir @ $(git -C "$CORES/$dir" rev-parse --short HEAD)"
}

# Clone a large repo lean: blobless + sparse to just the IP we need, pinned by SHA.
clone_sparse_pinned() {
  url=$1; dir=$2; sha=$3; sub=$4
  if [ ! -d "$DEPS/$dir/.git" ]; then
    git clone --quiet --filter=blob:none --sparse "$url" "$DEPS/$dir"
  fi
  git -C "$DEPS/$dir" sparse-checkout set "$sub" >/dev/null 2>&1 || true
  git -C "$DEPS/$dir" fetch --quiet origin
  git -C "$DEPS/$dir" -c advice.detachedHead=false checkout --quiet "$sha"
  echo "  deps/$dir @ $(git -C "$DEPS/$dir" rev-parse --short HEAD)  ($sub)"
}

echo "Fetching cores into $CORES and deps into $DEPS ..."
clone_pinned        "$ZX_URL"   zx             "$ZX_SHA"
clone_pinned        "$HDMI_URL" hdmi           "$HDMI_SHA"
clone_sparse_pinned "$VLIB_URL" vivado-library "$VLIB_SHA" "$VLIB_SUB"

echo "Done. A step can now be assembled and built:"
echo "  cd research/06-zx-spectrum-128/sources && ./assemble.sh && (cd build && vivado -mode batch -source build.tcl)"
