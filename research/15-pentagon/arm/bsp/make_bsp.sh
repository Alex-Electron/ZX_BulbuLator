#!/bin/bash
# make_bsp.sh - generate the Vitis 2023.1 workspace (platform + BSPs) that build_loader.sh compiles against.
#
#   research/15-pentagon/arm/bsp/make_bsp.sh            # -> research/15-pentagon/arm/bsp/ws
#   WS=/some/dir research/15-pentagon/arm/bsp/make_bsp.sh
#
# Steps: xsct creates the platform and both domains (create_platform.tcl) and builds them once from the
# stock Vitis sources; then patches/*.patch are applied to the core-0 BSP sources and that BSP is rebuilt.
# Finally an empty application skeleton ($WS/loader) is laid out for build_loader.sh.
#
# Env: WS (output workspace), XSA (hardware handoff, default: the .xsa next to this script),
#      MAKE_XSA=1 to regenerate that .xsa first with Vivado (make_xsa.tcl, ~30 s) instead of using the shipped one,
#      VITIS (default /tools/XilinxVitis/Vitis/2023.1), VIVADO (default /tools/Xilinx/Vivado/2023.1),
#      FORCE=1 to wipe an existing $WS.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="${WS:-$HERE/ws}"
XSA="${XSA:-$HERE/ebaz4205_ps7.xsa}"
VITIS="${VITIS:-/tools/XilinxVitis/Vitis/2023.1}"
VIVADO="${VIVADO:-/tools/Xilinx/Vivado/2023.1}"

[ -f "$VITIS/settings64.sh" ] || { echo "Vitis 2023.1 not found at $VITIS (set VITIS=...)"; exit 1; }
if [ -e "$WS/ebaz" ]; then
    if [ "$FORCE" = 1 ]; then rm -rf "$WS"; else echo "$WS/ebaz already exists (FORCE=1 to regenerate)"; exit 1; fi
fi
mkdir -p "$WS"
WS="$(cd "$WS" && pwd)"

if [ "$MAKE_XSA" = 1 ]; then
    echo "=== vivado: regenerate the hardware handoff ==="
    ( set +e; source "$VIVADO/settings64.sh" >/dev/null 2>&1; set -e
      cd "$WS" && vivado -mode batch -nojournal -nolog -source "$HERE/make_xsa.tcl" -tclargs "$WS/ebaz4205_ps7.xsa" )
    XSA="$WS/ebaz4205_ps7.xsa"
fi
[ -f "$XSA" ] || { echo "hardware handoff not found: $XSA"; exit 1; }

# settings64.sh is not written for `set -e`
set +e; source "$VITIS/settings64.sh" >/dev/null 2>&1; set -e
command -v arm-none-eabi-gcc >/dev/null || { echo "arm-none-eabi-gcc not in PATH"; exit 1; }
echo "=== toolchain: $(command -v arm-none-eabi-gcc) ($(arm-none-eabi-gcc -dumpversion))"

echo "=== xsct: platform + domains (about 30 s) ==="
xsct "$HERE/create_platform.tcl" "$WS" "$XSA"

BSP0="$WS/ebaz/ps7_cortexa9_0/standalone_domain/bsp"
BSP1="$WS/ebaz/ps7_cortexa9_1/ps7_cortexa9_1/bsp"
[ -f "$BSP0/ps7_cortexa9_0/lib/libxil.a" ] || { echo "core-0 BSP was not built"; exit 1; }
[ -f "$BSP1/ps7_cortexa9_1/lib/liblwip4.a" ] || { echo "core-1 BSP (lwIP) was not built"; exit 1; }

echo "=== patches -> core-0 BSP sources ==="
for p in "$HERE"/patches/*.patch; do
    echo "  $(basename "$p")"
    patch --batch --forward -p1 -d "$BSP0/ps7_cortexa9_0/libsrc" < "$p"
done

echo "=== rebuild core-0 BSP with the patched sources ==="
make -C "$BSP0" -s clean >/dev/null
make -C "$BSP0" -s all
grep -q 'MAX_TIMEOUT 0x1FFFFU' "$BSP0/ps7_cortexa9_0/include/xsdps.h" || { echo "patched xsdps.h did not reach include/"; exit 1; }
for o in ff.o ffunicode.o ffsystem.o; do
    [ -f "$BSP0/ps7_cortexa9_0/libsrc/xilffs_v5_0/src/$o" ] || { echo "missing xilffs object $o"; exit 1; }
done

echo "=== application skeleton $WS/loader ==="
mkdir -p "$WS/loader/src" "$WS/loader/Debug/src"
cp -f "$HERE/Xilinx.spec" "$WS/loader/src/Xilinx.spec"
cp -f "$HERE/Xilinx.spec" "$WS/loader/Debug/Xilinx.spec"

echo ">>> BSP READY: $WS"
echo "    next: WS=$WS research/15-pentagon/arm/build_loader.sh"
