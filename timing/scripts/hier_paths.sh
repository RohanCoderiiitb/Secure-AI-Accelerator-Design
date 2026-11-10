#!/usr/bin/env bash
# Hierarchical synthesis (no flattening) + pre-layout OpenSTA at the slow and
# fast corners: top-N setup paths with block names, and per-block area.
# Usage: scripts/hier_paths.sh <design_name>   (names in scripts/designs.sh)
# Output: results/<design>/hier/{hier_stat.txt,hier_paths_<corner>.{tsv,rpt,md}}
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
TIMING=$(dirname "$HERE")
REPO=$(dirname "$TIMING")
source "$HERE/designs.sh"
source "$HERE/pdk_gpdk045.sh"
export SDC=$TIMING/constraints.sdc
export SYN_LIB=${SYN_LIB:-$LIB_SLOW}

name=$1
row=""
for d in "${DESIGNS[@]}"; do [[ ${d%%|*} == "$name" ]] && row=$d; done
[[ -n $row ]] || { echo "unknown design: $name" >&2; exit 1; }
IFS='|' read -r _ TOP files PARAMS <<< "$row"
export TOP PARAMS
VERILOG_FILES=""
for f in $files; do VERILOG_FILES+="$REPO/$f "; done
export VERILOG_FILES

export OUT_DIR=$TIMING/results/$name/hier
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
echo "[$name] yosys (hierarchical)"
HIER=1 YOSYS_MAX_THREADS=1 yosys -q -l "$OUT_DIR/yosys.log" -c "$HERE/synth.tcl"
for c in slow fast; do
    lib=$LIB_SLOW; [[ $c == fast ]] && lib=$LIB_FAST
    echo "[$name] opensta $c (pre-layout, hierarchical)"
    STA_LIB=$lib STA_TAG=$c sta -no_splash -exit "$HERE/hier_paths.tcl" > "$OUT_DIR/sta_$c.log" 2>&1
    python3 "$HERE/summarize_paths.py" "$OUT_DIR/hier_paths_$c.tsv" "$name ($c corner)" > "$OUT_DIR/hier_paths_$c.md"
done
echo "[$name] done"
