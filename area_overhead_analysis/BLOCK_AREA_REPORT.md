# Per-Block Area — Masked Array + Masked Requantizer Accelerator (timing-closed)

**Design:** `flexnn_top_protected` (`protected_designs/complete_accelerator/top_protected.sv`), the
timing-closed build: 5×5 array, WAVES = 4, ACCW = XW = 19, MW = 16, `DOM_REG = 1`, **NRQ = 1**
(one shared masked requantizer core), registered I/O, pipelined PE multipliers. Same parameters as
the other three accelerator builds.
**Technology:** 45nm PDK — Cadence GPDK045 (`gsclib045`), slow library (`slow_vdd1v0`, the
library the `timing/` flow maps against)
**Metric:** pre-layout standard-cell area from Yosys (µm²), split into total and register (flip-flop) area

## How these numbers were obtained

The design was synthesised **hierarchically** by the `timing/` flow (`timing/scripts/synth.tcl`
with `HIER=1`): same RTL, parameters, cell library, `dont_use` list and ABC mapping as the
implementation netlist, but without flattening. Every module keeps its own boundary, so Yosys reports
each block separately.

No optimisation crosses block boundaries, so the hierarchical total (160,558 µm²) is higher than the
flattened synthesis of the same design (123,858 µm² pre-layout; 152,051 µm² post-route, see
`REPORT.md` §4.6). Use these numbers to compare blocks with each other, not as absolute area.
Every block total is the sum of its sub-blocks plus its own logic. Raw statistics:
`results/acc_both_masked/hier_stat.txt` (copied from `timing/results/acc_both_masked_nrq1/hier/`).

## Per block

| Block | Instances | Area each (µm²) | Total (µm²) | of which registers (µm²) | Share of design |
|---|---:|---:|---:|---:|---:|
| PEs (`processing_element_wshare`) | 25 | 2,533.5 | 63,338.4 | 14,364.0 (22.7 %) | 39.4 % |
| Shadow column (`shadow_pe`) | 5 | 2,303.0 | 11,515.1 | 2,106.7 (18.3 %) | 7.2 % |
| Mask generator (`wmask_gen`) | 1 | 1,684.3 | 1,684.3 | 870.0 (51.7 %) | 1.0 % |
| Array glue (north-edge subtractors, S delay line, load counter, valid delay) | 1 | 1,884.4 | 1,884.4 | 487.0 (25.8 %) | 1.2 % |
| Masked psum accumulator (`psum_accum_masked`) | 1 | 11,206.3 | 11,206.3 | 7,647.1 (68.2 %) | 7.0 % |
| Share buffer + select / routing (`rq_share_server` own logic) | 1 | 11,539.1 | 11,539.1 | 7,105.7 (61.6 %) | 7.2 % |
| Masked requantizer cores (`requantize_masked`) | 1 | 32,029.7 | 32,029.7 | 16,237.8 (50.7 %) | 19.9 % |
| Random number generators (`rng_bank`) | 1 | 7,527.4 | 7,527.4 | 2,800.0 (37.2 %) | 4.7 % |
| bias*m0 precompute (`bias_scale`) | 1 | 5,550.3 | 5,550.3 | 2,796.4 (50.4 %) | 3.5 % |
| **Masked blocks, subtotal** (all rows above except bias_scale) | | | **140,724.8** | 51,618.4 (36.7 %) | **87.6 %** |
| Unmasked rest (buffers, scratchpads, load controller, address generator, activation units, maxpools, registered I/O, top-level glue) | | | 14,283.3 | 10,365.1 | 8.9 % |
| **Total** | | | **160,558.4** | 64,779.9 (40.3 %) | 100 % |

| Group | Total (µm²) | Share of design |
|---|---:|---:|
| Masked array (PEs + shadow column + mask generator + glue) | 78,422.3 | 48.8 % |
| Masked psum accumulator | 11,206.3 | 7.0 % |
| Share buffer + routing | 11,539.1 | 7.2 % |
| Masked requantizer cores (×1) | 32,029.7 | 19.9 % |
| Random number generators (×1) | 7,527.4 | 4.7 % |
| bias*m0 precompute | 5,550.3 | 3.5 % |
| Unmasked rest | 14,283.3 | 8.9 % |

Inside one masked requantizer core (32,029.7 µm²):

| Part | Instances per core | Area per core (µm²) | of which registers (µm²) | Share of core |
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

- **PE:** 2,533 µm² each: the two-stage pipelined 8×19 share multiplier, the 19-bit weight-share
  and psum registers, the activation register and the psum adder.
- **Share buffer:** the per-column buffer that holds the two accumulator shares until the shared
  core serves that column (shares are never recombined), plus the round-robin select registers.
- **Random number generator:** one, for the one core (NRQ = 1).
- The core's internal datapath width is RW = XW + MW + 2 = 19 + 16 + 2 = 37 bits.

## Compared with the earlier, not timing-closed build

The earlier version of this report (5 masked cores, MW = 32, bias added before the multiply,
hierarchical total 392,942 µm²) had the requantizer cores at 63 % and the RNGs at 13 % of the design.
With one shared core, MW = 16 and bias·M0 precomputed, the requantizer path (core + RNG + share
buffer) is about 32 % and the masked array is now the largest block (49 %).
