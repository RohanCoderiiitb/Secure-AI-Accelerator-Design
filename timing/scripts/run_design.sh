#!/usr/bin/env bash
# Run one design through Yosys -> OpenROAD (multi-corner) -> OpenSTA (fast + slow).
# Usage: scripts/run_design.sh <design_name>     (names in scripts/designs.sh)
# Results: results/<design>/
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TIMING=$(dirname "$HERE")
REPO=$(dirname "$TIMING")
source "$HERE/designs.sh"

source "$HERE/pdk_gpdk045.sh"
for f in "$TECH_LEF" "$CELL_LEF" "$LIB_FAST" "$LIB_SLOW"; do
    [[ -f $f ]] || { echo "PDK file missing: $f" >&2; exit 1; }
done
# Router-compatible copy of the tech LEF (front-end via rules dropped; see
# make_router_tech_lef.py). Used by OpenROAD only; Yosys/OpenSTA need no LEF.
export ROUTER_TECH_LEF=$TIMING/results/pdk_derived/gsclib045_tech.router.lef
mkdir -p "$(dirname "$ROUTER_TECH_LEF")"
python3 "$HERE/make_router_tech_lef.py" "$TECH_LEF" "$ROUTER_TECH_LEF.$$" > /dev/null
mv "$ROUTER_TECH_LEF.$$" "$ROUTER_TECH_LEF"
# Slow library with only max_transition relaxed: DRV repair at the fast corner only (pnr.tcl).
export LIB_SLOW_DRV=$TIMING/results/pdk_derived/$(basename "$LIB_SLOW" .lib)_drvfast.lib
sed -E 's/(max_transition[[:space:]]*:[[:space:]]*)0\.28/\15.0/' "$LIB_SLOW" > "$LIB_SLOW_DRV.$$"
mv "$LIB_SLOW_DRV.$$" "$LIB_SLOW_DRV"
export SDC=$TIMING/constraints.sdc
export SYN_LIB=${SYN_LIB:-$LIB_SLOW}
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

export OUT_DIR=${OUT_ROOT:-$TIMING/results}/$name
# keep the hierarchical sub-run (hier_paths.sh) if there is one
mkdir -p "$OUT_DIR"
find "$OUT_DIR" -maxdepth 1 -type f -delete

echo "[$name] yosys"
# The installed Yosys dev build runs some optimisation passes multithreaded and
# they race on the large masked accelerators; single-threaded is deterministic.
export YOSYS_MAX_THREADS=${YOSYS_MAX_THREADS:-1}
HIER=0 yosys -q -l "$OUT_DIR/yosys.log" -c "$HERE/synth.tcl"
# Known nondeterministic Yosys issue: a small memory's write data treated as
# undefined and the memory deleted. Stop instead of reporting a wrong netlist.
if grep -q "removing const-x" "$OUT_DIR/yosys.log"; then
    echo "[$name] yosys removed memory lanes as constant-x (known Yosys issue): netlist is wrong, re-run" >&2
    exit 2
fi
echo "[$name] openroad (fast + slow corners)"
openroad -no_splash -exit -log "$OUT_DIR/openroad.log" "${PNR_TCL:-$HERE/pnr.tcl}" > /dev/null
echo "[$name] opensta (slow + fast corner)"
STA_LIB=$LIB_FAST STA_TAG=fast sta -no_splash -exit "$HERE/sta_postroute.tcl" > "$OUT_DIR/sta_fast.log" 2>&1
STA_LIB=$LIB_SLOW STA_TAG=slow sta -no_splash -exit "$HERE/sta_postroute.tcl" > "$OUT_DIR/sta_slow.log" 2>&1
echo "[$name] done: $(paste -sd' ' "$OUT_DIR/sta_metrics_slow.txt" | cut -c1-80)"
