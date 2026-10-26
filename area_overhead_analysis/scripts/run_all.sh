#!/usr/bin/env bash
# Run every design in scripts/designs.sh in parallel, then tabulate and plot.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
source "$HERE/designs.sh"

for d in "${DESIGNS[@]}"; do
    name=${d%%|*}
    # the two arrays dominate detailed-routing time; give them more threads
    case $name in sa_*) t=10 ;; *) t=2 ;; esac
    THREADS=$t "$HERE/run_design.sh" "$name" &
done
wait

python3 "$HERE/collect_metrics.py"
python3 "$HERE/plot_area.py"
