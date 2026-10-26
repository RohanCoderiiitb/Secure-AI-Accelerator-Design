#!/usr/bin/env bash
# Run one design through Yosys -> OpenROAD -> OpenSTA.
# Usage: scripts/run_design.sh <design_name>     (names in scripts/designs.sh)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ANALYSIS=$(dirname "$HERE")
REPO=$(dirname "$ANALYSIS")
source "$HERE/designs.sh"

export PLATFORM_DIR=${PLATFORM_DIR:-$HOME/OpenROAD-flow-scripts/flow/platforms/nangate45}
export LIB=$PLATFORM_DIR/lib/NangateOpenCellLibrary_typical.lib
export DONT_USE="TAPCELL_X1 FILLCELL_X1 AOI211_X1 OAI211_X1"
export SDC=$ANALYSIS/constraints/constraints.sdc
export CORE_UTIL=${CORE_UTIL:-50}
export PLACE_DENSITY=${PLACE_DENSITY:-0.60}
export THREADS=${THREADS:-4}

name=$1
row=""
for d in "${DESIGNS[@]}"; do
    [[ ${d%%|*} == "$name" ]] && row=$d
done
[[ -n $row ]] || { echo "unknown design: $name" >&2; exit 1; }

IFS='|' read -r _ TOP files PARAMS <<< "$row"
export TOP PARAMS
VERILOG_FILES=""
for f in $files; do VERILOG_FILES+="$REPO/$f "; done
export VERILOG_FILES

export OUT_DIR=$ANALYSIS/results/$name
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"

echo "[$name] yosys"
yosys -q -l "$OUT_DIR/yosys.log" -c "$HERE/synth.tcl"
echo "[$name] openroad"
openroad -no_splash -exit -log "$OUT_DIR/openroad.log" "$HERE/pnr.tcl" > /dev/null
echo "[$name] opensta"
sta -no_splash -exit "$HERE/sta_postroute.tcl" > "$OUT_DIR/sta.log" 2>&1
echo "[$name] done"
