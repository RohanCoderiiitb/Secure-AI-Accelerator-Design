`timescale 1ns/1ps
//=====================================================================
// tb_tvla_accelerator.sv -- TVLA dataset generation for the COMPLETE
//                           accelerator, weights as the secret
//
//   default : flexnn_top            (source/top.sv)          unprotected
//   -DPROT     : flexnn_top_protected  array + requantizer masked
//   -DRQ_ONLY  : flexnn_top_rq_masked  requantizer masked only
//   -DARR_ONLY : flexnn_top_arr_masked array masked only
//
// Per trace (both groups follow the same steps):
//   1. draw a random weight matrix AND a random activation tile (R5)
//   2. FIXED group: weights replaced by fix_w (one matrix for the run)
//   3. write activations / weights through the global-buffer ports and
//      start the accelerator               -- untriggered
//      (protected: mask refresh + weight load happen here)
//   4. capture CAPTURE cycles from the stream_start pulse: activation
//      streaming, array, psum accumulator, requantizer  -- triggered
//   5. wait for done, flush
//
// Dump scope (identical blocks in both designs, the weight-dependent
// datapath): systolic array PEs (+ shadow column in the protected one),
// psum accumulator, requantizers. Not dumped: global buffers, scratchpads,
// load controller (plain weights, load phase only), activation unit,
// maxpool, output buffer, and the protected design's mask generators.
//
// Plusargs: +NTRACES +SEED +MODE=tvla|null +TVLA_TARGET=wt +TAG +OUTDIR
//           +FIXSEED=<n>   seed of the fixed weight matrix only
//=====================================================================
module tb_tvla_accelerator;
    parameter N = 8, ACCW = 32, ROWS = 4, COLS = 4, WAVES = 4;
    parameter MW = 32, SW = 6, POOL_LEN = 1;
    parameter DOM_REG = 1;

    localparam real CLK_NS = 10.0;
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);
    localparam XW        = 2*N + $clog2(ROWS);

    `include "msk_counts.vh"
`ifdef PROT
    localparam RQ_LAT = mskf_rq_lat(XW, XW + MW + 2, DOM_REG);
`elsif RQ_ONLY
    localparam RQ_LAT = mskf_rq_lat(XW, XW + MW + 2, DOM_REG);
`else
    localparam RQ_LAT = 3;
`endif
    // stream_start -> last requantizer output, plus margin
    localparam CAPTURE = ROWS + WAVES + COLS + 4 + RQ_LAT + 4;

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg reset_n, start;
    reg if_wr_en, fl_wr_en;
    reg [IF_ADDR_W-1:0] if_wr_addr;
    reg [FL_ADDR_W-1:0] fl_wr_addr;
    reg [N-1:0] if_wr_data, fl_wr_data;
    reg [COLS*ACCW-1:0] bias_flat;
    reg [COLS*MW-1:0]   m0_flat;
    reg [COLS*SW-1:0]   shift_flat;
    wire done, acd;
    wire [COLS-1:0] ovf, sat;
    wire [COLS*N-1:0] of_data;

`ifdef PROT
    flexnn_top_protected #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                           .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN), .DOM_REG(DOM_REG)) u_top (
`elsif RQ_ONLY
    flexnn_top_rq_masked #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                           .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN), .DOM_REG(DOM_REG)) u_top (
`elsif ARR_ONLY
    flexnn_top_arr_masked #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                            .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)) u_top (
`else
    flexnn_top #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)) u_top (
`endif
        .clk(clk), .reset_n(reset_n), .start(start), .done(done), .array_compute_done(acd),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(2'd1), .act_clamp_high(8'sd100), .act_leaky_shift(3'd2),
        .pool_win_len({{(CW-1){1'b0}}, 1'b1}), .psum_ovf_flat(ovf), .requant_sat_flat(sat),
        .of_rd_en({COLS{1'b0}}), .of_rd_addr_flat({(COLS*OF_ADDR_W){1'b0}}), .of_rd_data_flat(of_data));

    // ---------------- dump scope ----------------
    genvar gr, gc, gp;
    generate
`ifdef PROT
  `define MASKED_ARRAY
`elsif ARR_ONLY
  `define MASKED_ARRAY
`endif
`ifdef MASKED_ARRAY
        // masked array: PEs + shadow column (mask generator / edge masking not dumped)
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_dr
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_dc
                initial begin #1; $dumpvars(0, u_top.u_array.g_row[gr].g_col[gc].pe_inst); end
            end
            initial begin #1; $dumpvars(0, u_top.u_array.g_shadow[gr].sh_inst); end
        end
`else
        initial begin #1; $dumpvars(0, u_top.u_array); end
`endif
        initial begin #1; $dumpvars(0, u_top.u_psum_accum); end
        for (gp = 0; gp < COLS; gp = gp + 1) begin : g_dp
            initial begin #1; $dumpvars(0, u_top.g_post[gp].u_requant); end
        end
    endgenerate

    `include "sca_capture.vh"

    reg signed [N-1:0] cur_w [0:FL_DEPTH-1];
    reg signed [N-1:0] fix_w [0:FL_DEPTH-1];
    reg signed [N-1:0] act   [0:IF_DEPTH-1];
    integer t, i, c, k, cyc, FIXSEED_I, fixseed_state;
    reg grp, eff, use_fixseed, done_seen;
    reg signed [N-1:0] tmp8;

    always @(posedge clk) if (done) done_seen <= 1'b1;

    initial begin
        sca_get_config("accelerator");
        if (TVLA_TARGET != "wt") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- only 'wt' (weights are the secret)", TVLA_TARGET);
            $finish;
        end
        use_fixseed   = $value$plusargs("FIXSEED=%d", FIXSEED_I);
        fixseed_state = FIXSEED_I;
        for (i = 0; i < FL_DEPTH; i = i + 1)
            fix_w[i] = use_fixseed ? $random(fixseed_state) : rand_i8(0);

        // public per-layer constants, identical in both groups
        for (c = 0; c < COLS; c = c + 1) begin
            bias_flat[c*ACCW +: ACCW] = 32'sd137;
            m0_flat[c*MW +: MW]       = 32'sh4E8B_1C00;     // ~0.618 in Q0.31
            shift_flat[c*SW +: SW]    = 6'd38;
        end

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
`ifdef PROT
        sca_open_meta("flexnn_top_protected", CLK_NS, CAPTURE);
`elsif RQ_ONLY
        sca_open_meta("flexnn_top_rq_masked", CLK_NS, CAPTURE);
`elsif ARR_ONLY
        sca_open_meta("flexnn_top_arr_masked", CLK_NS, CAPTURE);
`else
        sca_open_meta("flexnn_top", CLK_NS, CAPTURE);
`endif
        $display("[SCA] accelerator %0dx%0d WAVES=%0d capture=%0d cycles (requant latency %0d)",
                 ROWS, COLS, WAVES, CAPTURE, RQ_LAT);

        reset_n = 0; start = 0; if_wr_en = 0; fl_wr_en = 0;
        if_wr_addr = 0; fl_wr_addr = 0; if_wr_data = 0; fl_wr_data = 0;
        repeat (6) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (40) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: random weights and activations drawn for BOTH groups
            for (i = 0; i < FL_DEPTH; i = i + 1) cur_w[i] = rand_i8(0);
            for (i = 0; i < IF_DEPTH; i = i + 1) act[i]   = rand_i8(0);
            if (!eff) for (i = 0; i < FL_DEPTH; i = i + 1) cur_w[i] = fix_w[i];

            // ---- memory writes + start: untriggered ----
            for (i = 0; i < IF_DEPTH; i = i + 1) begin
                @(negedge clk); if_wr_en = 1; if_wr_addr = i; tmp8 = act[i]; if_wr_data = tmp8;
            end
            @(negedge clk); if_wr_en = 0;
            for (i = 0; i < FL_DEPTH; i = i + 1) begin
                @(negedge clk); fl_wr_en = 1; fl_wr_addr = i; tmp8 = cur_w[i]; fl_wr_data = tmp8;
            end
            @(negedge clk); fl_wr_en = 0;
            done_seen = 1'b0;
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;

            // ---- wait for the compute phase (after mask refresh + weight load) ----
            k = 0;
            while (u_top.stream_start !== 1'b1 && k < 1000) begin @(negedge clk); k = k + 1; end
            if (k >= 1000) begin $display("[SCA] FATAL: stream_start never seen"); $finish; end

            // ---- capture window ----
            for (cyc = 0; cyc < CAPTURE; cyc = cyc + 1) begin
                @(posedge clk);
                if (cyc == 0) sca_trace_begin;
            end
            @(negedge clk);
            sca_trace_end(grp);

            // ---- let the run finish, untriggered ----
            k = 0;
            while (!done_seen && k < 1000) begin @(negedge clk); k = k + 1; end
            if (!done_seen) begin $display("[SCA] FATAL: done never seen"); $finish; end
            repeat (4) @(negedge clk);

            if (t % 200 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
