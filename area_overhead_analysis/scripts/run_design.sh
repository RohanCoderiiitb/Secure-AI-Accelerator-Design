#!/usr/bin/env bash
# Run one design through Yosys -> OpenROAD -> OpenSTA.
# Usage: scripts/run_design.sh <design_name>     (names in scripts/designs.sh)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ANALYSIS=$(dirname "$HERE")
REPO=$(dirname "$ANALYSIS")
source "$HERE/designs.sh"

source "$HERE/pdk_gpdk045.sh"
for f in "$TECH_LEF" "$CELL_LEF" "$LIB_FAST" "$LIB_SLOW"; do
    [[ -f $f ]] || { echo "PDK file missing: $f" >&2; exit 1; }
done
# Router-compatible copy of the tech LEF (front-end via rules dropped; see
# make_router_tech_lef.py). Used by OpenROAD only; Yosys/OpenSTA need no LEF.
export ROUTER_TECH_LEF=$ANALYSIS/results/pdk_derived/gsclib045_tech.router.lef
mkdir -p "$(dirname "$ROUTER_TECH_LEF")"
python3 "$HERE/make_router_tech_lef.py" "$TECH_LEF" "$ROUTER_TECH_LEF.$$" > /dev/null
mv "$ROUTER_TECH_LEF.$$" "$ROUTER_TECH_LEF"
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
echo "[$name] opensta (slow + fast corner)"
STA_LIB=$LIB_FAST STA_TAG=fast sta -no_splash -exit "$HERE/sta_postroute.tcl" > "$OUT_DIR/sta_fast.log" 2>&1
STA_LIB=$LIB_SLOW STA_TAG=slow sta -no_splash -exit "$HERE/sta_postroute.tcl" > "$OUT_DIR/sta_slow.log" 2>&1
echo "[$name] done"
