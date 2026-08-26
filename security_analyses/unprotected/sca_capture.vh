//=====================================================================
// sca_capture.vh  --  shared TVLA capture infrastructure
//---------------------------------------------------------------------
// `include this INSIDE a testbench module body. Compile with
// -g2012 (Icarus) / -sv (Xcelium, Questa). The only SystemVerilog
// feature used is the `string` type, for plusargs and filenames. The
// DUTs themselves stay pure Verilog-2001.
//
// Provides:
//   * xorshift64* PRNG (simulator-independent, reproducible via +SEED=)
//   * plusarg run configuration
//   * a metadata sidecar recording each trace's group label and its
//     exact [t_start,t_end] window in nanoseconds
//
// Rules this file enforces. Each is a TVLA correctness requirement,
// not a style preference:
//
//   R1  ONE continuous simulation for all N traces. No per-trace VCD.
//       Traces are sliced post-hoc from the metadata windows. Per-trace
//       files multiply elaboration cost and, at gate level with Joules,
//       make the run infeasible.
//   R2  Group order is a RANDOM PERMUTATION of a balanced label vector,
//       never alternating. Alternating order aliases with any monotonic
//       simulator-state drift and manufactures a t-statistic.
//   R3  Group labels live in a sidecar file, NOT in a register inside
//       the dumped scope. A group-ID register inside the DUT scope
//       leaks the label straight into the power proxy and yields a
//       guaranteed t >> 4.5 that means nothing.
//   R4  Setup phases (reset, weight load, pipeline flush) are OUTSIDE
//       the trigger window.
//   R5  Both populations draw the same number of PRNG words, so the
//       values seen by the random group do not depend on how many
//       fixed traces happened to precede them.
//   R6  MODE=null runs fixed-vs-fixed with labels still randomly
//       interleaved. Mandatory infrastructure check: run it, confirm
//       max|t| stays under 4.5, and only then believe a real result.
//
// On $dumpoff/$dumpon gating: deliberately not offered. It loses the
// register transitions at the first posedge of each window (they occur
// while dumping is off, and the $dumpon checkpoint absorbs them without
// counting), and because $dumpoff/$dumpon each re-emit every net in the
// scope, it makes the VCD LARGER whenever the untriggered gap is short
// -- which it is here. For file size, dump FST instead:
//     vvp -fst build/tb.vvp ...     (or $dumpfile with an .fst name)
//     fst2vcd dump.fst | python3 py/vcd_power.py --vcd - ...
// The parser reads stdin and .gz directly.
//
// Timescale: the enclosing TB must declare `timescale 1ns/1ps. Metadata
// times use $realtime, i.e. nanoseconds as a real. The VCD header
// timescale (1ps under Icarus) is resolved by the Python parser, so the
// two never have to agree.
//=====================================================================

//---------------------------------------------------------------------
// Run configuration
//---------------------------------------------------------------------
integer NTRACES;        // total traces, split exactly 50/50
integer SEED;           // PRNG seed
string  MODE;           // "tvla" | "null"
string  TVLA_TARGET;    // "act" | "wt" | "both"
string  TAG;            // output filename tag
string  OUTDIR;         // output directory

//---------------------------------------------------------------------
// PRNG: xorshift64*. $random is deliberately never used -- its stream
// is simulator-defined, which makes a leakage result unreproducible
// across Icarus / Xcelium / Questa.
//---------------------------------------------------------------------
reg [63:0] prng_state;

function [63:0] xs64s(input integer dummy);
    reg [63:0] x;
    begin
        x = prng_state;
        x = x ^ (x >> 12);
        x = x ^ (x << 25);
        x = x ^ (x >> 27);
        prng_state = x;
        xs64s = x * 64'd2685821657736338717;
    end
endfunction

// Uniform signed INT8 over the full [-128,127] range.
function signed [7:0] rand_i8(input integer dummy);
    reg [63:0] r;
    begin
        r       = xs64s(0);
        rand_i8 = r[40:33];      // upper bits are the best bits of xorshift*
    end
endfunction

function rand_bit(input integer dummy);
    reg [63:0] r;
    begin
        r        = xs64s(0);
        rand_bit = r[63];
    end
endfunction

// Uniform w-bit word, w <= 64.
function [63:0] rand_word(input integer w);
    reg [63:0] r;
    begin
        r         = xs64s(0);
        rand_word = r >> (64 - w);
    end
endfunction

//---------------------------------------------------------------------
// Balanced, randomly permuted group schedule
//---------------------------------------------------------------------
localparam SCHED_MAX = 262144;
reg group_sched [0:SCHED_MAX-1];   // 0 = FIXED, 1 = RANDOM

task build_group_schedule;
    integer i, j;
    reg     tmp;
    begin
        for (i = 0; i < NTRACES; i = i + 1)
            group_sched[i] = (i < (NTRACES/2)) ? 1'b0 : 1'b1;
        for (i = NTRACES - 1; i > 0; i = i - 1) begin   // Fisher-Yates
            j              = xs64s(0) % (i + 1);
            tmp            = group_sched[i];
            group_sched[i] = group_sched[j];
            group_sched[j] = tmp;
        end
    end
endtask

//---------------------------------------------------------------------
// Metadata sidecar
//---------------------------------------------------------------------
integer meta_fd;
real    trace_t0;
integer trace_id;

task sca_open_meta(input string dut_name, input real clk_period_ns,
                   input integer capture_cycles);
    string path;
    begin
        path    = {OUTDIR, "/", TAG, ".meta.csv"};
        meta_fd = $fopen(path, "w");
        if (meta_fd == 0) begin
            $display("[SCA] FATAL: cannot open %0s", path);
            $finish;
        end
        $fdisplay(meta_fd, "# dut=%0s",            dut_name);
        $fdisplay(meta_fd, "# mode=%0s",           MODE);
        $fdisplay(meta_fd, "# tvla_target=%0s",    TVLA_TARGET);
        $fdisplay(meta_fd, "# seed=%0d",           SEED);
        $fdisplay(meta_fd, "# ntraces=%0d",        NTRACES);
        $fdisplay(meta_fd, "# clk_period_ns=%0f",  clk_period_ns);
        $fdisplay(meta_fd, "# capture_cycles=%0d", capture_cycles);
        $fdisplay(meta_fd, "# time_unit=ns");
        $fdisplay(meta_fd, "trace_id,group,t_start_ns,t_end_ns");
        trace_id = 0;
    end
endtask

// Call immediately after the posedge at which the first captured cycle
// begins, i.e. once the operands for cycle 0 are already driven.
task sca_trace_begin;
    begin
        trace_t0 = $realtime;
    end
endtask

// Call after the posedge that ends the last captured cycle.
task sca_trace_end(input grp);   // 0 = FIXED, 1 = RANDOM
    begin
        $fdisplay(meta_fd, "%0d,%0s,%0f,%0f",
                  trace_id, (grp ? "R" : "F"), trace_t0, $realtime);
        trace_id = trace_id + 1;
    end
endtask

task sca_close_meta;
    begin
        $fclose(meta_fd);
        $display("[SCA] wrote %0s/%0s.meta.csv  (%0d traces)", OUTDIR, TAG, trace_id);
    end
endtask

//---------------------------------------------------------------------
// Config bootstrap
//---------------------------------------------------------------------
task sca_get_config(input string default_tag);
    begin
        if (!$value$plusargs("NTRACES=%d",     NTRACES))     NTRACES     = 2000;
        if (!$value$plusargs("SEED=%d",        SEED))        SEED        = 1;
        if (!$value$plusargs("MODE=%s",        MODE))        MODE        = "tvla";
        if (!$value$plusargs("TVLA_TARGET=%s", TVLA_TARGET)) TVLA_TARGET = "act";
        if (!$value$plusargs("TAG=%s",         TAG))         TAG         = default_tag;
        if (!$value$plusargs("OUTDIR=%s",      OUTDIR))      OUTDIR      = "traces";

        if (NTRACES > SCHED_MAX) begin
            $display("[SCA] FATAL: NTRACES > %0d, enlarge SCHED_MAX", SCHED_MAX);
            $finish;
        end
        if (NTRACES % 2 != 0) NTRACES = NTRACES - 1;

        prng_state = 64'd88172645463325252 + SEED;
        build_group_schedule;

        $display("[SCA] tag=%0s mode=%0s target=%0s ntraces=%0d seed=%0d",
                 TAG, MODE, TVLA_TARGET, NTRACES, SEED);
    end
endtask

// In "null" mode both populations are the FIXED population, while the
// labels stay randomly interleaved, so the t-test sees exactly the
// estimator it will see in the real experiment.
function effective_random(input grp);
    effective_random = (MODE == "null") ? 1'b0 : grp;
endfunction
