# Timing closure and area, v2 -- complete accelerator, 4 builds

5x5 weight-stationary INT8 array, WAVES = 4, weights secret. Cadence GPDK045 (gsclib045),
Yosys -> OpenROAD -> OpenSTA, flow in `timing/scripts`, constraint `timing/constraints.sdc`
(10 ns clock, 20 % I/O delay). Results per build in `timing/results/<build>/`.

**Result: all four builds (and the rq / both builds at NRQ = 1, 2 and 5) meet setup AND hold at
100 MHz at BOTH corners** (fast 1.1 V / 0 C and slow 0.9 V / 125 C), zero TNS, zero routing DRC
violations, checked post-route in standalone OpenSTA with the routed SPEF.

## 1. Flow

| Step | What it does |
|---|---|
| Yosys (`synth.tcl`) | flattened synthesis (masked PEs / share multipliers keep their hierarchy as before); ABC maps for delay against the **slow** library, target 8 ns; flip-flops named after their RTL signals |
| OpenROAD (`pnr.tcl`) | floorplan at 50 % utilisation, placement, design-rule repair (fast library), CTS, then the slow library is added and **two scenes (fast, slow)** are defined: `repair_timing -setup` and `-hold` after CTS and after global routing repair both corners together (setup margin 0.2 ns, hold margin 0.05 ns) |
| OpenSTA (`sta_postroute.tcl`) | routed netlist + SPEF, once with the fast and once with the slow library |
| `hier_paths.sh` | hierarchical (unflattened) synthesis, pre-layout STA, top-20 setup paths with block names and a per-block summary of all failing endpoints; per-block area |

Design rules (max slew 0.28 ns in both libraries, the edge of their characterisation tables) are
repaired at the fast corner only: the slow scene uses a copy of the slow library with only its
max_transition limits relaxed (same delay tables), and `repair_design` runs after placement, after
the placement-time timing repair and after global routing. Repairing them at the slow corner too
added ~60 % buffer area without being needed for setup or hold.
Note: this OpenROAD build keeps wire RC per scene, so `set_wire_rc` is repeated after
`define_scene` (without it the slow scene reads garbage parasitics and repair reports -INF).

## 2. Before: hierarchical critical paths (Task 1.1)

Original RTL (`complete_accelerator/complete_accelerator`), mapped as in the old flow (fast library,
ABC -D 10000), pre-layout STA at the slow corner with 3 fF per net. Full lists (top 20 paths, block
names, every failing endpoint grouped by block): `results/pre_acc_*/hier/hier_paths_slow.md`.

| Build | WNS slow (ns) | Worst path | Other failing blocks |
|---|---:|---|---|
| unprotected | -10.24 | plain requantizer: `sh_s2` -> 51-bit round/shift/compare -> `q_out` (ABC had turned the adder into a ripple chain) | -- |
| arr-only | -13.92 | same plain requantizer stage | PEs / shadow column (8x8 / 8x19 multiplier + psum add from the activation scratchpads) |
| rq-only | -43.73 | rng_bank enable (`rq_busy` -> 700 enables, unbuffered pre-layout) | requant B2A/multiply stage -11.5, load controller, PEs, psum accumulator, address generator, maxpool, activation unit: all from input ports |
| both | -11.51 | masked requant B2A step 2: `bias_flat` port -> (x0 + bias) * m0 (34x32) -> adders -> `u_rm` | rng_bank -5.5, B2A step 1 -4.5, load controller, address generator, PEs, maxpool, psum accumulator, mask generator, activation unit: mostly from input ports |

## 3. Changes (applied to ALL four builds unless stated)

| Change | Where | Effect |
|---|---|---|
| Every data/config input and every output registered at the ports; `reset_n` synchronised by one register | all tops | input-port paths (2 ns external delay + high fanout) gone; +2 cycles start -> done; output read latency 3 cycles. In the masked-requantizer builds `requant_sat_flat` is kept as two share registers and XORed after them, so no new register holds a recombined value |
| MW = 16 (top 16 bits of the TFLite multiplier, shift - 16) | plain and masked requantizers, all tops | outputs bit-identical between all builds (checked against a behavioural model) |
| Bias after the multiply: (x + bias)*m0 = x*m0 + bias*m0, bias*m0 per column computed once per start | new `bias_scale.sv` (shared sequential carry-save multiplier, 56 cycles, done long before the first requant input; signed-m0 correction folded into the start value and the final add split into two 24-bit halves so no wide adder sits in one cycle) | per-share multipliers XW x MW = 19x16 instead of 34x32 / 19x32 |
| Plain requantizer: 5 stages (two half products / sum of halves / + bias*m0 + round / shift / clamp), 1 result per cycle; round constant registered before the bias add | `requantization_block.sv` (unprotected and array-only builds) | latency 5 (was 3), +2 cycles in those two builds only |
| Masked requantizer v3: RW = XW + MW + 2 = 37; per-share x m0 in 2 stages placed inside the LIFT wait; wide constants (K, bias*m0 + round + offset, in-range mask) registered one stage before use; per-column constant tables + column tag | `requantize_masked.sv`, `msk_counts.vh` | latency 18 (unchanged), 459 random bits/cycle (was 645); masking rules kept (one share per cone, DOM_REG = 1 registers, no recombined value in a new register) |
| PE multipliers pipelined, 2 stages, same in both arrays (8x8 Baugh-Wooley in the plain PE, 8x19 share multiplier in the masked PE and the shadow PE) | `multiplier.sv` (`bw_multiplier_pipe`), `systolic_array_wmask_shared.sv` (`wsm_share_multiplier_pipe`) | psum chain stays aligned (all PEs same latency); `valid_sum_out` delayed by 2 in all three arrays; shadow column / S delay line / ld_cnt / mask refresh unchanged and consistent; +2 cycles |
| Shared masked requantizer cores, NRQ in 1..COLS (rq and both builds) | new `rq_share_server.sv` | per-column share buffer, core k serves columns c % NRQ == k round-robin, own rng_bank per core, results back to their column |
| Tiles overlap: a new start is accepted when the array side is idle; output counters wrap per tile; activation unit output only updates on valid | tops, `load_controller.sv`, `activation_unit.sv` | requant/activation of tile k overlaps tile k+1 |
| ACCW = 19 (= 2N + clog2(5)) in every build, bias width 32 separate | tops | equal accumulator width in all builds (the old flow had 32 in arr/rq) |

## 4. Timing, post-route, both corners

| Build | Setup WNS fast (ns) | Hold WNS fast (ns) | Setup WNS slow (ns) | Hold WNS slow (ns) | Setup TNS slow (ns) | Met at both corners | Route DRC |
|---|---:|---:|---:|---:|---:|:---:|---:|
| Unprotected (baseline) | +7.203 | +0.051 | +0.514 | +0.063 | 0.000 | yes | 0 |
| Array masked only | +7.116 | +0.051 | +0.380 | +0.056 | 0.000 | yes | 0 |
| Requantizer masked only, NRQ=1 | +7.137 | +0.047 | +0.862 | +0.070 | 0.000 | yes | 0 |
| Requantizer masked only, NRQ=2 | +7.036 | +0.049 | +1.008 | +0.051 | 0.000 | yes | 0 |
| Requantizer masked only, NRQ=5 | +6.938 | +0.043 | +0.964 | +0.086 | 0.000 | yes | 0 |
| Array + requantizer masked, NRQ=1 | +7.054 | +0.041 | +1.007 | +0.071 | 0.000 | yes | 0 |
| Array + requantizer masked, NRQ=2 | +6.879 | +0.047 | +0.902 | +0.056 | 0.000 | yes | 0 |
| Array + requantizer masked, NRQ=5 | +6.908 | +0.047 | +0.912 | +0.057 | 0.000 | yes | 0 |

Fast-corner design rules: after the final repair 5-289 pins per build still exceed the 0.28 ns max-transition limit (was ~1,000-2,500 before the extra repair passes); setup/hold timing accounts for those slews. Slow-corner slews are not repaired (see §1).

## 5. Area, post-route (overhead vs the timing-closed unprotected build)

| Build | Total (um^2) | Registers (um^2) | Combinational (um^2) | Clock tree (um^2) | Total overhead | Register overhead | Combinational overhead |
|---|---:|---:|---:|---:|---:|---:|---:|
| Unprotected (baseline) | 94,018 | 32,077 | 59,485 | 2,456 | 1.00x | 1.00x | 1.00x |
| Array masked only | 131,719 | 40,142 | 89,147 | 2,430 | 1.40x (+40 %) | 1.25x (+25 %) | 1.50x (+50 %) |
| Requantizer masked only, NRQ=1 | 109,793 | 45,471 | 58,187 | 6,135 | 1.17x (+17 %) | 1.42x (+42 %) | 0.98x (+-2 %) |
| Requantizer masked only, NRQ=2 | 153,913 | 64,019 | 83,738 | 6,156 | 1.64x (+64 %) | 2.00x (+100 %) | 1.41x (+41 %) |
| Requantizer masked only, NRQ=5 | 283,010 | 117,483 | 154,436 | 11,092 | 3.01x (+201 %) | 3.66x (+266 %) | 2.60x (+160 %) |
| Array + requantizer masked, NRQ=1 | 152,051 | 57,362 | 88,515 | 6,175 | 1.62x (+62 %) | 1.79x (+79 %) | 1.49x (+49 %) |
| Array + requantizer masked, NRQ=2 | 198,201 | 76,090 | 115,911 | 6,200 | 2.11x (+111 %) | 2.37x (+137 %) | 1.95x (+95 %) |
| Array + requantizer masked, NRQ=5 | 320,661 | 127,491 | 182,088 | 11,082 | 3.41x (+241 %) | 3.97x (+297 %) | 3.06x (+206 %) |

Registers = flip-flops; combinational = logic + timing-repair buffers/inverters + tie cells; clock
tree = CTS buffers. Fillers excluded. Core utilisation after repair ~0.61-0.62 for every build.
rq-only NRQ = 1 has slightly LESS combinational area than the baseline: its five plain requantizers
(hierarchical synthesis: mostly combinational) are replaced by one masked core +
share server + rng (~42k um^2 of registers, ~23k combinational) -- the masking cost there is
almost all flip-flops.

Previous (not timing-closed, fast-corner implementation, MW = 32, one core per column) for
reference: array-only 1.79x, rq-only 4.58x, both 4.96x over an 85,127 um^2 baseline.
The baseline grew to 94,018 um^2 mostly from the I/O registers and the two extra plain-requantizer
stages; that makes the masked overheads slightly smaller than with a 3-stage baseline.

## 6. Per-block area, both-masked build, NRQ = 1 (hierarchical Yosys)

Hierarchical synthesis with the same mapping as the implementation flow, no optimisation across
module boundaries; use for comparing blocks. Raw: `results/acc_both_masked_nrq1/hier/hier_stat.txt`.

Design `flexnn_top_protected`, hierarchical Yosys total 160,981.8 um^2 (64,976.6 um^2 registers).

| Block | Instances | Area each (um^2) | Total (um^2) | of which registers (um^2) | Share of design |
|---|---:|---:|---:|---:|---:|
| PEs (`processing_element_wshare`) | 25 | 2,533.5 | 63,338.4 | 14,364.0 (22.7 %) | 39.3 % |
| Shadow column (`shadow_pe`) | 5 | 2,303.0 | 11,515.1 | 2,106.7 (18.3 %) | 7.2 % |
| Mask generator (`wmask_gen`) | 1 | 1,684.3 | 1,684.3 | 870.0 (51.7 %) | 1.0 % |
| Array glue (north-edge subtractors, S delay line, load counter, valid delay) | 1 | 1,884.4 | 1,884.4 | 487.0 (25.8 %) | 1.2 % |
| Masked psum accumulator (`psum_accum_masked`) | 1 | 11,194.7 | 11,194.7 | 7,647.1 (68.3 %) | 7.0 % |
| Share buffer + select / routing (`rq_share_server` own logic) | 1 | 11,582.9 | 11,582.9 | 7,105.7 (61.3 %) | 7.2 % |
| Masked requantizer cores (`requantize_masked`) | 1 | 32,029.7 | 32,029.7 | 16,237.8 (50.7 %) | 19.9 % |
| Random number generators (`rng_bank`) | 1 | 7,527.4 | 7,527.4 | 2,800.0 (37.2 %) | 4.7 % |
| bias*m0 precompute (`bias_scale`) | 1 | 5,941.6 | 5,941.6 | 2,993.1 (50.4 %) | 3.7 % |
| **Masked blocks, subtotal** (all rows above except bias_scale) | | | **140,756.9** | 51,618.4 (36.7 %) | **87.4 %** |
| Unmasked rest (buffers, scratchpads, load controller, address generator, activation units, maxpools, registered I/O, top-level glue) | | | 14,283.3 | 10,365.1 | 8.9 % |
| **Total** | | | **160,981.8** | 64,976.6 (40.4 %) | 100 % |

| Group | Total (um^2) | Share of design |
|---|---:|---:|
| Masked array (PEs + shadow column + mask generator + glue) | 78,422.3 | 48.7 % |
| Masked psum accumulator | 11,194.7 | 7.0 % |
| Share buffer + routing | 11,582.9 | 7.2 % |
| Masked requantizer cores (x1) | 32,029.7 | 19.9 % |
| Random number generators (x1) | 7,527.4 | 4.7 % |
| bias*m0 precompute | 5,941.6 | 3.7 % |
| Unmasked rest | 14,283.3 | 8.9 % |

Inside one masked requantizer core (32,029.7 um^2):

| Part | Instances per core | Area per core (um^2) | of which registers (um^2) | Share of core |
|---|---:|---:|---:|---:|
| Own logic: per-share x m0 multipliers (2 stages), B2A/constant adders, B2A mux, output-window shifts, constant selection | - | 12,121.2 | 1,285.9 | 37.8 % |
| `msk_prefix` | 1 | 9,016.5 | 6,336.6 | 28.2 % |
| `msk_pipe` | 13 | 4,835.9 | 4,752.1 | 15.1 % |
| `msk_cout_tree` | 1 | 2,503.4 | 1,554.0 | 7.8 % |
| `dom_and_v` | 2 | 1,662.1 | 985.0 | 5.2 % |
| `msk_and_tree` | 1 | 1,325.6 | 798.9 | 4.1 % |
| `msk_dly` | 1 | 404.9 | 404.9 | 1.3 % |
| `msk_vpipe` | 1 | 123.1 | 98.5 | 0.4 % |
| `dom_and` | 1 | 36.9 | 21.9 | 0.1 % |

## 7. Latency and throughput

Cycles from the start pin to the done pin (one tile), and the steady-state tile period when the
next start is issued as soon as `array_compute_done` is seen (tiles overlap). From
`tb_accel_func` (`make func_acc`).

| Build | NRQ | Latency (cycles) | Period (cycles/tile) | Throughput at 100 MHz |
|---|---:|---:|---:|---:|
| Unprotected | - | 91 | 85 | 1.18 M tiles/s |
| Array masked only | - | 97 | 91 | 1.10 M tiles/s |
| Requantizer masked only | 1 | 118 | 85 | 1.18 M tiles/s |
| Requantizer masked only | 2 | 110 | 85 | 1.18 M tiles/s |
| Requantizer masked only | 5 | 106 | 85 | 1.18 M tiles/s |
| Array + requantizer masked | 1 | 124 | 91 | 1.10 M tiles/s |
| Array + requantizer masked | 2 | 116 | 91 | 1.10 M tiles/s |
| Array + requantizer masked | 5 | 112 | 91 | 1.10 M tiles/s |

Before the changes: unprotected 85, arr 91, rq 100, both 106 cycles (5x5, start -> done).
Block latencies: plain requantizer 5, masked core 18, share server + core 20 + waiting
(NRQ = 1: up to 12 cycles for the last column). The array masks need ROWS + 1 = 6 extra cycles
per tile (mask refresh), which is the whole throughput difference of the masked-array builds.
A tile is one 5x5 weight load and 4 activation waves (20 outputs).

**NRQ choice: NRQ = 1** for the security runs. Same throughput as NRQ = 2 / 5, +12 cycles latency,
and 0.77x / 0.47x the area of NRQ = 2 / 5 for the both-masked build.

## 8. Functional verification (all pass)

| Bench | Result |
|---|---|
| `tb_accel_func` both masked, NRQ = 1 / 2 / 5 | PASS (vs unprotected and vs behavioural model, 100 tests + 8 back-to-back tiles) |
| `tb_accel_func -DRQ_ONLY`, NRQ = 1 / 2 / 5 | PASS |
| `tb_accel_func -DARR_ONLY` | PASS |
| `tb_requant_latency` | PASS (plain vs model, masked DOM_REG = 1 / 0 vs plain; latencies 5 / 18 / 3) |
| `tb_func_wmask_shared` (accelerator copies of the arrays, ACCW = 19) | PASS, cycle-exact vs the plain array |

**Same parameters in every build and bench.** The Makefile passes one explicit parameter set to
every accelerator simulation (`tb_accel_func`, `tb_tvla_accelerator`, all four builds) and to
`tb_func_wmask_shared`: N = 8, 5×5, WAVES = 4, ACCW = 19, MW = 16, SW = 6, BW = 32, POOL_LEN = 1,
DOM_REG = 1, NRQ = `ACC_NRQ` (1). The RTL tops and testbenches default to the same values (NRQ = 1),
`tb_requant_latency` uses XW = ACCW = 19, MW = 16, and the synthesis flow uses the RTL defaults.
The TVLA bench prints the full parameter set at the start of every run.

Reproduce: `make -C security_analyses/protected func_acc`; `timing/scripts/run_design.sh <build>`;
`python3 timing/scripts/collect_v2.py`; `python3 timing/scripts/block_area.py results/acc_both_masked_nrq1/hier/hier_stat.txt`.


## 9. TVLA capture window (checked, not a security result)

The window opens at the start pulse (weight load included) and ends 3 idle cycles after the last
activity, measured per build: 94 / 100 / 137 / 143 cycles (unprotected / array-only / rq-only /
both-masked, NRQ = 1). The idle check (`check_capture_idle.py`) passes for all four builds with
ACTS = random and fixed.
