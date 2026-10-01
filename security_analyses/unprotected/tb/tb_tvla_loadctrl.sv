`timescale 1ns/1ps
//=====================================================================
// tb_tvla_loadctrl.sv -- TVLA dataset generation for load_controller.
//
// The load_controller FSM drives:
//   ACT_FETCH  -- reads IF_GB serially and writes per-row spads
//   WT_COL_FETCH / WT_PRESENT -- reads FL_GB and assembles wt_flat
//   STREAM_KICK/WAIT -- pulses stream_start into address_generator
//
// All three phases produce data-dependent switching on the internal
// buses (if_rd_data, fl_rd_data, wt_flat, row_wr_data, act_flat via
// the connected address_generator+spads).  The capture window covers
// the entire start→done handshake so every phase is included.
//
// DUT: load_controller, together with:
//   u_if_gb   -- global_buffer (IF feature-map)
//   u_fl_gb   -- global_buffer (filter / weight)
//   g_spad[]  -- per-row activation scratchpads
//   u_ag      -- address_generator (activation streaming)
//   The systolic array is NOT instantiated; valid_sum_out is instead
//   driven by a small synthetic model (see its declaration below) that
//   reproduces the real array's south-edge completion timing, since
//   load_controller's own `done` is gated on address_generator's
//   compute_done, which in turn is gated on valid_sum_out actually
//   pulsing -- tying it to constant 0 hangs load_controller forever.
//
// TVLA contrast (TVLA_TARGET):
//   "ifmap"  (default) -- activation bytes in IF_GB vary; weights fixed
//   "wt"               -- weight bytes in FL_GB vary; activations fixed
//
// Geometry:
//   ARRAY_ROWS  default 4
//   ARRAY_COLS  default 4
//   WAVES       default 4
//   N           default 8  (INT8)
//=====================================================================
module tb_tvla_loadctrl;

    parameter N          = 8;
    parameter ARRAY_ROWS = 4;
    parameter ARRAY_COLS = 4;
    parameter WAVES      = 4;

    localparam IF_DEPTH  = ARRAY_ROWS * WAVES;
    localparam FL_DEPTH  = ARRAY_ROWS * ARRAY_COLS;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam WADDR_W   = (WAVES    <= 1) ? 1 : $clog2(WAVES);
    localparam RA_W      = (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);

    // Worst-case transaction length (generous upper bound):
    //   ACT_FETCH:     IF_DEPTH + 2 cycles
    //   WT_COL_FETCH:  ARRAY_ROWS * (ARRAY_COLS + 2) cycles
    //   STREAM:        ARRAY_ROWS + WAVES + 2 cycles
    // Total rounded up to next power of two.
    localparam MAX_CYCLES = 256;
    localparam real CLK_NS = 10.0;

    reg clk = 1'b0;
    reg reset_n, start;
    wire done;

    // IF_GB write port (testbench-driven)
    reg                   if_wr_en;
    reg  [IF_ADDR_W-1:0]  if_wr_addr;
    reg  [N-1:0]          if_wr_data;

    // FL_GB write port (testbench-driven)
    reg                   fl_wr_en;
    reg  [FL_ADDR_W-1:0]  fl_wr_addr;
    reg  [N-1:0]          fl_wr_data;

    // Internal wires: IF_GB <-> load_controller
    wire                   if_rd_en;
    wire [IF_ADDR_W-1:0]   if_rd_addr;
    wire [N-1:0]           if_rd_data;

    // Internal wires: FL_GB <-> load_controller
    wire                   fl_rd_en;
    wire [FL_ADDR_W-1:0]   fl_rd_addr;
    wire [N-1:0]           fl_rd_data;

    // Row scratchpad write ports
    wire [ARRAY_ROWS-1:0]         row_wr_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] row_wr_addr_flat;
    wire [N-1:0]                  row_wr_data;

    // Weight load
    wire                      wt_load;
    wire [ARRAY_COLS*N-1:0]   wt_flat;

    // Address generator handshake
    wire stream_start;
    wire compute_done;

    // Address generator -> scratchpad read
    wire [ARRAY_ROWS-1:0]         act_rd_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] act_rd_addr_flat;
    wire [ARRAY_ROWS-1:0]         act_valid;
    wire [ARRAY_ROWS*N-1:0]       act_flat;

    // BUG FIX: valid_sum_out was tied permanently to 0 with the comment
    // "no downstream systolic array". But address_generator's compute_done
    // -- which load_controller's S_STREAM_WAIT state blocks on to ever
    // reach S_DONE/assert done -- only fires once out_cnt[ARRAY_COLS-1]
    // reaches WAVES, which only increments on valid_sum_out[ARRAY_COLS-1]
    // pulses. Tying valid_sum_out to constant 0 makes compute_done
    // structurally unreachable, so load_controller hangs in S_STREAM_WAIT
    // forever and every trace times out (the "did not assert done within
    // 256 cycles" spam) -- this isn't a stats/capture issue, it's this
    // testbench never supplying the handshake load_controller depends on.
    //
    // Fix: since correctness of the actual psum VALUES is irrelevant to
    // this testbench (it targets load_controller/address_generator timing
    // and leakage, not the array's arithmetic), emulate the completion
    // handshake a real systolic_array + accumulator would produce, rather
    // than instantiating the whole array. In the real array, column c's
    // south-edge valid pulse for a given wave lands exactly c cycles after
    // column 0's (one extra cycle per column of eastward activation
    // travel), and column 0's own pulse train is identical in timing to
    // act_valid[ARRAY_ROWS-1] (the bottom row's registered read-valid,
    // already delayed 1 cycle from act_rd_en by address_generator) -- that
    // is exactly when the last row's MAC result would reach the south edge
    // of column 0. So: valid_sum_out[0] = act_valid[ARRAY_ROWS-1], and
    // valid_sum_out[c] = that same pulse train shifted c cycles later.
    reg  [ARRAY_COLS-1:0] valid_sum_out_r;
    integer vsc;
    always @(posedge clk) begin
        if (!reset_n) begin
            valid_sum_out_r <= {ARRAY_COLS{1'b0}};
        end else begin
            valid_sum_out_r[0] <= act_valid[ARRAY_ROWS-1];
            for (vsc = 1; vsc < ARRAY_COLS; vsc = vsc + 1)
                valid_sum_out_r[vsc] <= valid_sum_out_r[vsc-1];
        end
    end
    wire [ARRAY_COLS-1:0]         valid_sum_out  = valid_sum_out_r;
    wire [ARRAY_COLS-1:0]         out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;
    wire                          stream_busy;

    // ---- IF_GB ----
    (* dont_touch = "yes" *)
    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (IF_DEPTH),
        .GB_ADDR_WIDTH (IF_ADDR_W)
    ) u_if_gb (
        .clk     (clk),
        .wr_en   (if_wr_en),
        .wr_addr (if_wr_addr),
        .wr_data (if_wr_data),
        .rd_en   (if_rd_en),
        .rd_addr (if_rd_addr),
        .rd_data (if_rd_data)
    );

    // ---- FL_GB ----
    (* dont_touch = "yes" *)
    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (FL_DEPTH),
        .GB_ADDR_WIDTH (FL_ADDR_W)
    ) u_fl_gb (
        .clk     (clk),
        .wr_en   (fl_wr_en),
        .wr_addr (fl_wr_addr),
        .wr_data (fl_wr_data),
        .rd_en   (fl_rd_en),
        .rd_addr (fl_rd_addr),
        .rd_data (fl_rd_data)
    );

    // ---- load_controller ----
    (* dont_touch = "yes" *)
    load_controller #(
        .N          (N),
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_lc (
        .clk              (clk),
        .reset_n          (reset_n),
        .start            (start),
        .done             (done),
        .if_rd_en         (if_rd_en),
        .if_rd_addr       (if_rd_addr),
        .if_rd_data       (if_rd_data),
        .row_wr_en        (row_wr_en),
        .row_wr_addr_flat (row_wr_addr_flat),
        .row_wr_data      (row_wr_data),
        .fl_rd_en         (fl_rd_en),
        .fl_rd_addr       (fl_rd_addr),
        .fl_rd_data       (fl_rd_data),
        .wt_load          (wt_load),
        .wt_flat          (wt_flat),
        .stream_start     (stream_start),
        .compute_done     (compute_done)
    );

    // ---- Per-row activation scratchpads ----
    genvar gr;
    generate
        for (gr = 0; gr < ARRAY_ROWS; gr = gr + 1) begin : g_spad
            scratchpad #(.DATA_WIDTH(N), .SPAD_DEPTH(WAVES)) u_spad (
                .clk     (clk),
                .wr_en   (row_wr_en[gr]),
                .wr_addr (row_wr_addr_flat[gr*WADDR_W +: WADDR_W]),
                .wr_data (row_wr_data),
                .rd_en   (act_rd_en[gr]),
                .rd_addr (act_rd_addr_flat[gr*WADDR_W +: WADDR_W]),
                .rd_data (act_flat[gr*N +: N])
            );
        end
    endgenerate

    // ---- address_generator ----
    (* dont_touch = "yes" *)
    address_generator #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_ag (
        .clk              (clk),
        .reset_n          (reset_n),
        .stream_start     (stream_start),
        .stream_busy      (stream_busy),
        .compute_done     (compute_done),
        .act_rd_en        (act_rd_en),
        .act_rd_addr_flat (act_rd_addr_flat),
        .act_valid        (act_valid),
        .valid_sum_out    (valid_sum_out),
        .out_wr_en        (out_wr_en),
        .out_wr_addr_flat (out_wr_addr_flat)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg [N-1:0] fix_if [0:IF_DEPTH-1];
    reg [N-1:0] fix_fl [0:FL_DEPTH-1];
    reg [N-1:0] cur_if [0:IF_DEPTH-1];
    reg [N-1:0] cur_fl [0:FL_DEPTH-1];

    integer t, i, cyc;
    reg grp, eff;

    // Write a byte array to IF_GB or FL_GB (untriggered, R4)
    task write_if_gb;
        integer ii;
        begin
            for (ii = 0; ii < IF_DEPTH; ii = ii + 1) begin
                @(negedge clk);
                if_wr_en   = 1'b1;
                if_wr_addr = ii[IF_ADDR_W-1:0];
                if_wr_data = cur_if[ii];
                @(posedge clk);
            end
            @(negedge clk);
            if_wr_en = 1'b0;
        end
    endtask

    task write_fl_gb;
        integer ii;
        begin
            for (ii = 0; ii < FL_DEPTH; ii = ii + 1) begin
                @(negedge clk);
                fl_wr_en   = 1'b1;
                fl_wr_addr = ii[FL_ADDR_W-1:0];
                fl_wr_data = cur_fl[ii];
                @(posedge clk);
            end
            @(negedge clk);
            fl_wr_en = 1'b0;
        end
    endtask

    // Wait for done to pulse, up to MAX_CYCLES
    task wait_done;
        integer cnt;
        begin
            cnt = 0;
            while (!done && cnt < MAX_CYCLES) begin
                @(posedge clk);
                cnt = cnt + 1;
            end
            if (cnt == MAX_CYCLES)
                $display("[SCA] WARNING: load_controller did not assert done within %0d cycles", MAX_CYCLES);
        end
    endtask

    initial begin
        sca_get_config("loadctrl");

        for (i = 0; i < IF_DEPTH; i = i + 1) fix_if[i] = rand_i8(0);
        for (i = 0; i < FL_DEPTH; i = i + 1) fix_fl[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        // Dump all sub-modules; mem[] arrays dumped explicitly
        $dumpvars(0, u_lc);
        $dumpvars(0, u_ag);

        // BUG FIX: u_lc/u_ag are the control FSMs. This file's own header
        // comment names if_rd_data, fl_rd_data, wt_flat, row_wr_data and
        // act_flat as the signals that actually carry data-dependent
        // switching. wt_flat and row_wr_data are registered *inside* u_lc,
        // so the two dumpvars(0, ...) calls above already capture them --
        // but if_rd_data and fl_rd_data are outputs of u_if_gb/u_fl_gb, and
        // act_flat comes from the g_spad[] scratchpads: all three live in
        // SIBLING instances that neither dumpvars(0,...) call ever reaches.
        // That silently drops the write-side read-data path (if_rd_data,
        // fl_rd_data) and the entire STREAM_KICK/STREAM_WAIT phase's data
        // path (act_flat) from the capture -- leaving those phases of the
        // window with no data-dependent signal at all. All three are plain
        // packed wires (not unpacked memory arrays), so plain dumpvars
        // calls are enough; no per-word/per-lane workaround needed.
        $dumpvars(1, if_rd_data);
        $dumpvars(1, fl_rd_data);
        $dumpvars(1, act_flat);

        // mem[] arrays: frozen the moment the write phase ends (reads never
        // rewrite them), so they show no transitions inside the capture
        // window. Kept for diagnostic visibility only -- not a substitute
        // for the three dumpvars calls above.
        for (i = 0; i < IF_DEPTH && i < 64; i = i + 1)
            $dumpvars(1, u_if_gb.u_mem.mem[i]);
        for (i = 0; i < FL_DEPTH && i < 64; i = i + 1)
            $dumpvars(1, u_fl_gb.u_mem.mem[i]);
        for (i = 0; i < WAVES; i = i + 1) begin
            $dumpvars(1, g_spad[0].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[1].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[2].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[3].u_spad.u_mem.mem[i]);
        end

        sca_open_meta("load_controller", CLK_NS, MAX_CYCLES);
        $display("[SCA] loadctrl ROWS=%0d COLS=%0d WAVES=%0d IF_DEPTH=%0d FL_DEPTH=%0d",
                 ARRAY_ROWS, ARRAY_COLS, WAVES, IF_DEPTH, FL_DEPTH);

        reset_n    = 1'b0;
        start      = 1'b0;
        if_wr_en   = 1'b0; if_wr_addr = {IF_ADDR_W{1'b0}}; if_wr_data = {N{1'b0}};
        fl_wr_en   = 1'b0; fl_wr_addr = {FL_ADDR_W{1'b0}}; fl_wr_data = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // BUG FIX: only the TARGETED buffer should ever be randomized.
            // The previous version drew fresh random data for BOTH IF_DEPTH
            // and FL_DEPTH unconditionally every trial ("R5: fresh for both
            // groups") and then overwrote only the buffer named by
            // TVLA_TARGET with the fixed pattern for effectively-fixed
            // trials. R5 only requires that the TARGETED variable's random
            // population draw the same number of PRNG words regardless of
            // label (so PRNG state doesn't depend on how many fixed trials
            // preceded it) -- it does not call for re-randomizing the
            // UNTARGETED buffer too. Because that untargeted buffer was
            // never pinned, it stayed genuinely random every trial in BOTH
            // groups AND in both MODE=null and MODE=tvla (effective_random
            // forces grp=0 in null mode, but that only controls which
            // vector the *targeted* overwrite below uses -- it never
            // touched the untargeted buffer). Welch's t has no mean-bias
            // from this (both groups see the identical uncontrolled random
            // stream), but at finite NTRACES it still has real, non-zero
            // sampling noise wherever genuine variance exists in BOTH
            // groups -- i.e. at every cycle touched by the untargeted
            // buffer's fetch phase. Since it's the same uncontrolled random
            // stream driving both the null run and the tvla run, both show
            // the identical noisy shape there. Fix: hold the untargeted
            // buffer at ONE constant pattern for every trial, so it
            // contributes zero variance (and hence zero jitter) anywhere,
            // in either mode; only ever randomize the buffer actually under
            // test, and only draw fresh PRNG words for that one (R5).
            if (TVLA_TARGET == "wt") begin
                for (i = 0; i < IF_DEPTH; i = i + 1) cur_if[i] = fix_if[i];  // untargeted: pinned every trial
                for (i = 0; i < FL_DEPTH; i = i + 1) cur_fl[i] = rand_i8(0); // R5: targeted, fresh for both groups
                if (!eff)
                    for (i = 0; i < FL_DEPTH; i = i + 1) cur_fl[i] = fix_fl[i];
            end else begin   // default "ifmap"/"act"
                for (i = 0; i < FL_DEPTH; i = i + 1) cur_fl[i] = fix_fl[i];  // untargeted: pinned every trial
                for (i = 0; i < IF_DEPTH; i = i + 1) cur_if[i] = rand_i8(0); // R5: targeted, fresh for both groups
                if (!eff)
                    for (i = 0; i < IF_DEPTH; i = i + 1) cur_if[i] = fix_if[i];
            end

            // ---- setup: write memories, untriggered (R4) ----
            write_if_gb;
            write_fl_gb;

            // ---- flush / resync ----
            repeat (4) @(posedge clk);

            // ---- capture window: full start->done transaction ----
            @(negedge clk);
            start = 1'b1;
            @(posedge clk);
            sca_trace_begin;
            @(negedge clk);
            start = 1'b0;

            wait_done;
            @(posedge clk);
            sca_trace_end(grp);

            // Extra quiesce before next write phase
            repeat (4) @(posedge clk);

            if (t % 100 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule