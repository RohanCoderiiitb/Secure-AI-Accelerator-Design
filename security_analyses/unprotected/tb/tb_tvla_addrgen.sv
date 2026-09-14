`timescale 1ns/1ps
//=====================================================================
// tb_tvla_addrgen.sv -- TVLA dataset generation for address_generator
//                       together with the per-row activation scratchpads
//                       it reads.
//
// Leakage surface:
//   address_generator sequences act_rd_en and act_rd_addr_flat, so the
//   activation data that propagates through the SRAM read path and onto
//   act_flat is the secret.  The generator's own internal counters toggle
//   identically in both groups (addresses are data-independent), but the
//   data returned on act_flat depends on what was written to the spads.
//
// DUT hierarchy (not the full systolic array):
//   ARRAY_ROWS scratchpads (one per row, each WAVES deep) driven by the
//   testbench for the write phase, then read through address_generator
//   during the capture window.
//   The valid_sum_out and out_wr_en / out_wr_addr_flat ports are not
//   connected to any downstream block; valid_sum_out is held zero so
//   the output-side de-skew counters stay idle.
//
// Protocol:
//   Setup (untriggered, R4):
//     Write the activation tile into each row's scratchpad.
//     Fixed group:  same tile every trace.
//     Random group: random tile every trace.
//   Capture window:
//     Pulse stream_start; observe CAPTURE = ARRAY_ROWS + WAVES + 2
//     cycles (fills and drains the staggered read pipeline).
//
// Compile-time knobs:
//   ARRAY_ROWS  default 4
//   ARRAY_COLS  default 4
//   WAVES       default 4
//=====================================================================
module tb_tvla_addrgen;

    parameter ARRAY_ROWS = 4;
    parameter ARRAY_COLS = 4;
    parameter WAVES      = 4;
    parameter N          = 8;

    localparam WADDR_W  = (WAVES <= 1) ? 1 : $clog2(WAVES);
    localparam real CLK_NS = 10.0;
    // The stream runs for ARRAY_ROWS + WAVES - 1 cycles; add extra
    // cycles for act_valid pipeline (1 cycle) and a drain margin.
    localparam CAPTURE = ARRAY_ROWS + WAVES + 2;
    localparam FLUSH   = 4;

    reg  clk = 1'b0;
    reg  reset_n;
    reg  stream_start;

    // address_generator outputs to scratchpads
    wire [ARRAY_ROWS-1:0]         act_rd_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] act_rd_addr_flat;
    wire [ARRAY_ROWS-1:0]         act_valid;

    // Tie off the output capture side (no downstream array)
    wire [ARRAY_COLS-1:0] valid_sum_out = {ARRAY_COLS{1'b0}};
    wire [ARRAY_COLS-1:0] out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;
    wire                  stream_busy;
    wire                  compute_done;

    (* dont_touch = "yes" *)
    address_generator #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_dut (
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

    // Per-row activation scratchpads
    reg  [ARRAY_ROWS-1:0]         spad_wr_en;
    reg  [ARRAY_ROWS*WADDR_W-1:0] spad_wr_addr_flat;
    reg  [N-1:0]                  spad_wr_data;
    wire [ARRAY_ROWS*N-1:0]       act_flat;

    genvar gr;
    generate
        for (gr = 0; gr < ARRAY_ROWS; gr = gr + 1) begin : g_spad
            scratchpad #(.DATA_WIDTH(N), .SPAD_DEPTH(WAVES)) u_spad (
                .clk     (clk),
                .wr_en   (spad_wr_en[gr]),
                .wr_addr (spad_wr_addr_flat[gr*WADDR_W +: WADDR_W]),
                .wr_data (spad_wr_data),
                .rd_en   (act_rd_en[gr]),
                .rd_addr (act_rd_addr_flat[gr*WADDR_W +: WADDR_W]),
                .rd_data (act_flat[gr*N +: N])
            );
        end
    endgenerate

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    // Tile storage
    reg signed [N-1:0] fix_tile [0:ARRAY_ROWS-1][0:WAVES-1];
    reg signed [N-1:0] cur_tile [0:ARRAY_ROWS-1][0:WAVES-1];

    integer t, r, w, cyc;
    reg     grp, eff;

    // Write the current tile into the ARRAY_ROWS scratchpads (untriggered)
    task write_spads;
        integer rr, ww;
        begin
            for (rr = 0; rr < ARRAY_ROWS; rr = rr + 1) begin
                for (ww = 0; ww < WAVES; ww = ww + 1) begin
                    @(negedge clk);
                    spad_wr_en   = {ARRAY_ROWS{1'b0}};
                    spad_wr_en[rr]                          = 1'b1;
                    spad_wr_addr_flat[rr*WADDR_W +: WADDR_W] = ww[WADDR_W-1:0];
                    spad_wr_data = cur_tile[rr][ww];
                    @(posedge clk);
                end
            end
            @(negedge clk);
            spad_wr_en = {ARRAY_ROWS{1'b0}};
            spad_wr_data = {N{1'b0}};
        end
    endtask

    initial begin
        sca_get_config("addrgen");

        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            for (w = 0; w < WAVES; w = w + 1)
                fix_tile[r][w] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        // Also dump the spad mem arrays for full switching visibility
        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            for (w = 0; w < WAVES; w = w + 1) begin
                case (r)
                    0: $dumpvars(1, g_spad[0].u_spad.u_mem.mem[w]);
                    1: $dumpvars(1, g_spad[1].u_spad.u_mem.mem[w]);
                    2: $dumpvars(1, g_spad[2].u_spad.u_mem.mem[w]);
                    3: $dumpvars(1, g_spad[3].u_spad.u_mem.mem[w]);
                    default: ;
                endcase
            end

        sca_open_meta("address_generator", CLK_NS, CAPTURE);
        $display("[SCA] addrgen ARRAY_ROWS=%0d WAVES=%0d capture=%0d cycles",
                 ARRAY_ROWS, WAVES, CAPTURE);

        reset_n       = 1'b0;
        stream_start  = 1'b0;
        spad_wr_en    = {ARRAY_ROWS{1'b0}};
        spad_wr_addr_flat = {(ARRAY_ROWS*WADDR_W){1'b0}};
        spad_wr_data  = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: always draw random tile for both groups
            for (r = 0; r < ARRAY_ROWS; r = r + 1)
                for (w = 0; w < WAVES; w = w + 1)
                    cur_tile[r][w] = rand_i8(0);

            // Fixed group: overwrite with the constant tile
            if (!eff)
                for (r = 0; r < ARRAY_ROWS; r = r + 1)
                    for (w = 0; w < WAVES; w = w + 1)
                        cur_tile[r][w] = fix_tile[r][w];

            // ---- write spads, untriggered (R4) ----
            write_spads;

            // ---- flush, untriggered ----
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            // Pulse stream_start for one cycle, then watch for CAPTURE cycles.
            @(negedge clk);
            stream_start = 1'b1;
            @(posedge clk);
            sca_trace_begin;
            @(negedge clk);
            stream_start = 1'b0;

            repeat (CAPTURE - 1) @(posedge clk);
            sca_trace_end(grp);

            // Let the stream fully quiesce before the next write phase.
            repeat (FLUSH) @(posedge clk);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
