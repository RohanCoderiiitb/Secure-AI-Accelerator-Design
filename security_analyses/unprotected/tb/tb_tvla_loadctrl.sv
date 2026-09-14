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
//   The systolic array is NOT instantiated; valid_sum_out is held low.
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

    // Tie off: no downstream systolic array
    wire [ARRAY_COLS-1:0]         valid_sum_out  = {ARRAY_COLS{1'b0}};
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

            // R5: draw fresh random data for both groups
            for (i = 0; i < IF_DEPTH; i = i + 1) cur_if[i] = rand_i8(0);
            for (i = 0; i < FL_DEPTH; i = i + 1) cur_fl[i] = rand_i8(0);

            // Fixed group uses the constant vectors
            if (!eff) begin
                if (TVLA_TARGET == "wt") begin
                    for (i = 0; i < FL_DEPTH; i = i + 1) cur_fl[i] = fix_fl[i];
                end else begin   // default "ifmap"
                    for (i = 0; i < IF_DEPTH; i = i + 1) cur_if[i] = fix_if[i];
                end
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
