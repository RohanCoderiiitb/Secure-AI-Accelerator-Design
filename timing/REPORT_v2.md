# Timing check -- complete accelerator, array + requantizer masked

**Design:** `flexnn_top_protected` from `protected_designs/complete_accelerator/` (RTL as of 2026-11-17:
masked weight storage, masked activation units after the requantizer cores, per-column re-masking in
the share buffer). 5x5 array, WAVES = 4, ACCW = 19, MW = 16, BW = 32, DOM_REG = 1, **NRQ = 1**.
**Technology:** Cadence GPDK045 (gsclib045), fast `fast_vdd1v0` (1.1 V, 0 C) and slow `slow_vdd1v0`
(0.9 V, 125 C).
**Constraint:** `timing/constraints.sdc` -- 100 MHz (10 ns), 20 % input/output delay.
**Run:** 2026-11-17, results in `timing/results/acc_both_masked_nrq1/`.

**Result: timing met at 100 MHz at both corners, setup and hold, post-route.**

## Timing (post-route, standalone OpenSTA with the routed SPEF)

| Corner | Setup WNS (ns) | Setup TNS (ns) | Hold WNS (ns) | Hold TNS (ns) |
|---|---:|---:|---:|---:|
| Fast (1.1 V, 0 C) | +7.026 | 0.000 | +0.048 | 0.000 |
| Slow (0.9 V, 125 C) | +0.799 | 0.000 | +0.064 | 0.000 |

Routing: 0 DRC violations.

Worst paths:
- Slow-corner setup: `u_rqs.g_core[0].u_core.ct[6][2]_reg` -> `u_rqs.g_core[0].u_core.g_mul_p.ph1q[25]_reg`
  (masked requantizer core: column tag -> constant selection -> per-share x m0 multiplier), slack +0.80 ns.
  The next endpoints are in the same multiplier and the A0 register of the core (+0.92 to +0.97 ns).
- Fast-corner setup: `sat0_q[4]_reg` -> output port `requant_sat_flat[4]` (I/O delay limited), slack +7.03 ns.
- Hold: +0.048 ns (fast) and +0.064 ns (slow).

Design rules: max transition (0.28 ns) is repaired at the fast corner only; 47 pins remain slightly above
the limit there and 2 nets above max capacitance. Setup and hold analysis include those slews. The slow
corner's slew limit is not enforced (almost every net exceeds 0.28 ns at 0.9 V / 125 C; repairing it
there added ~60 % buffer area without being needed for timing).

## Area (post-route standard-cell area, fillers excluded)

| Component | Area (um^2) |
|---|---:|
| Registers (10,648 flip-flops) | 67,653 |
| Combinational logic | 74,826 |
| Buffers / inverters (timing and design-rule repair) | 24,070 |
| Clock tree | 6,176 |
| Tie cells | 1 |
| **Total** | **172,727** |

Yosys (pre-layout) area 139,277 um^2. Core 276,974 um^2 at 62.4 % utilisation, die 531.8 x 531.8 um.

## Flow

| Step | What it does |
|---|---|
| Yosys (`scripts/synth.tcl`) | flattened synthesis; ABC maps for delay against the slow library (target 8 ns); single-threaded |
| OpenROAD (`scripts/pnr.tcl`) | floorplan at 50 % utilisation, placement, design-rule repair (fast corner), CTS; then the slow library is added and two scenes (fast, slow) are defined: setup and hold repaired at both corners together (setup margin 0.2 ns, hold margin 0.05 ns) after CTS and after global routing, with design-rule repair after each step; detailed routing |
| OpenSTA (`scripts/sta_postroute.tcl`) | routed netlist + SPEF, once with the fast and once with the slow library |

Reproduce: `timing/scripts/run_design.sh acc_both_masked_nrq1` (PDK paths in `scripts/pdk_gpdk045.sh`).
The timing result applies to the RTL as it was on 2026-11-17; re-run after any RTL change.
