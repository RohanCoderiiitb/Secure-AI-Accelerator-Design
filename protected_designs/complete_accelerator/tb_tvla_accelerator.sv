`timescale 1ns/1ps
// TVLA dataset for the complete accelerator, weights secret (+ACTS=random|fixed, +DUMP_TAIL, -DPROT/-DRQ_ONLY/-DARR_ONLY)
module tb_tvla_accelerator;
    parameter N = 8, ACCW = 19, ROWS = 5, COLS = 5, WAVES = 4;
    parameter MW = 16, SW = 6, BW = 32, POOL_LEN = 1;
    parameter DOM_REG = 1;
    parameter NRQ = 1;                     // shared masked requantizer cores (evaluated configuration)

    localparam real CLK_NS = 10.0;
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);
    localparam XW        = 2*N + $clog2(ROWS);
    localparam IDLE_TAIL = 3;

    `include "msk_counts.vh"
`ifdef PROT
  `define MASKED_RQ
`elsif RQ_ONLY
  `define MASKED_RQ
`endif
`ifdef MASKED_RQ
    localparam RQ_LAT = mskf_rq_lat(XW, XW + MW + 2, DOM_REG);
`else
    localparam RQ_LAT = 5;
`endif

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg reset_n, start;
    reg if_wr_en, fl_wr_en;
    reg [IF_ADDR_W-1:0] if_wr_addr;
    reg [FL_ADDR_W-1:0] fl_wr_addr;
    reg [N-1:0] if_wr_data, fl_wr_data;
    reg [COLS*BW-1:0]   bias_flat;
    reg [COLS*MW-1:0]   m0_flat;
    reg [COLS*SW-1:0]   shift_flat;
    wire done, acd;
    wire [COLS-1:0] ovf, sat;
    wire [COLS*N-1:0] of_data;

`ifdef PROT
    flexnn_top_protected #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                           .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN), .DOM_REG(DOM_REG), .NRQ(NRQ)) u_top (
`elsif RQ_ONLY
    flexnn_top_rq_masked #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                           .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN), .DOM_REG(DOM_REG), .NRQ(NRQ)) u_top (
`elsif ARR_ONLY
    flexnn_top_arr_masked #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                            .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN)) u_top (
`else
    flexnn_top #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN)) u_top (
`endif
        .clk(clk), .reset_n(reset_n), .start(start), .done(done), .array_compute_done(acd),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(2'd1), .act_clamp_high(8'sd100), .act_leaky_shift(3'd2),
        .pool_win_len({{(CW-1){1'b0}}, 1'b1}), .psum_ovf_flat(ovf), .requant_sat_flat(sat),
        .of_rd_en({COLS{1'b0}}), .of_rd_addr_flat({(COLS*OF_ADDR_W){1'b0}}), .of_rd_data_flat(of_data));

    integer DUMP_TAIL_I;
    string  ACTS;

    // dump scope
    genvar gr, gc, gp, gk, gw;
    generate
`ifdef PROT
  `define MASKED_ARRAY
`elsif ARR_ONLY
  `define MASKED_ARRAY
`endif
`ifdef MASKED_ARRAY
        // masked array
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
`ifdef MASKED_RQ
        // share server: whole scope (buffers, select registers, cores). Indexed hierarchical paths
        // through genvars (g_buf[gc], g_core[gk]) crash iverilog 13 (eval_vec4 assertion).
        initial begin #1; $dumpvars(0, u_top.u_rqs); end
`else
        for (gp = 0; gp < COLS; gp = gp + 1) begin : g_dp
            initial begin #1; $dumpvars(0, u_top.g_post[gp].u_requant); end
        end
`endif
        // DUMP_TAIL
        for (gp = 0; gp < COLS; gp = gp + 1) begin : g_dt
            initial begin
                #1;
                if (DUMP_TAIL_I != 0) begin
                    $dumpvars(0, u_top.g_post[gp].u_act);
                    $dumpvars(0, u_top.g_post[gp].u_pool);
                    $dumpvars(0, u_top.g_of_spad[gp].u_of_spad);
                end
            end
            for (gw = 0; gw < OF_DEPTH; gw = gw + 1) begin : g_dw
                initial begin
                    #1;
                    if (DUMP_TAIL_I != 0) $dumpvars(0, u_top.g_of_spad[gp].u_of_spad.u_mem.mem[gw]);
                end
            end
        end
    endgenerate

    // activity monitors for the window calibration
    wire rng_on;
`ifdef MASKED_RQ
    wire [NRQ-1:0] rng_en_v;
    generate
        for (gk = 0; gk < NRQ; gk = gk + 1) begin : g_re
            assign rng_en_v[gk] = u_top.u_rqs.g_core[gk].rng_en;
        end
    endgenerate
    assign rng_on = |rng_en_v;
`else
    assign rng_on = 1'b0;
`endif
    wire int_done = u_top.post_done;          // last output-buffer write (before the pin register)

    `include "sca_capture.vh"

    reg signed [N-1:0] cur_w [0:FL_DEPTH-1];
    reg signed [N-1:0] fix_w [0:FL_DEPTH-1];
    reg signed [N-1:0] act   [0:IF_DEPTH-1];
    reg signed [N-1:0] fix_a [0:IF_DEPTH-1];
    integer t, i, c, k, cyc, FIXSEED_I, fixseed_state;
    integer CAPTURE, k_done, k_rng, quiet;
    reg grp, eff, use_fixseed, done_seen, acts_fixed;
    reg signed [N-1:0] tmp8;

    always @(posedge clk) if (done) done_seen <= 1'b1;

    // write activations + weights (untriggered) and pulse start; the window opens at the next edge
    task load_and_start;
        begin
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
        end
    endtask

    task finish_tile;
        begin
            k = 0;
            while (!done_seen && k < 1000) begin @(negedge clk); k = k + 1; end
            if (!done_seen) begin $display("[SCA] FATAL: done never seen"); $finish; end
            repeat (4) @(negedge clk);
        end
    endtask

    initial begin
        sca_get_config("accelerator");
        if (TVLA_TARGET != "wt") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- only 'wt' (weights are the secret)", TVLA_TARGET);
            $finish;
        end
        if (!$value$plusargs("ACTS=%s", ACTS)) ACTS = "random";
        if (ACTS != "random" && ACTS != "fixed") begin
            $display("[SCA] FATAL: ACTS=%0s -- use random or fixed", ACTS);
            $finish;
        end
        acts_fixed = (ACTS == "fixed");
        if (!$value$plusargs("DUMP_TAIL=%d", DUMP_TAIL_I)) DUMP_TAIL_I = acts_fixed ? 1 : 0;

        use_fixseed   = $value$plusargs("FIXSEED=%d", FIXSEED_I);
        fixseed_state = FIXSEED_I;
        for (i = 0; i < FL_DEPTH; i = i + 1) begin
            if (use_fixseed) begin tmp8 = $random(fixseed_state); fix_w[i] = tmp8; end
            else             begin tmp8 = rand_i8(0);             fix_w[i] = tmp8; end
        end
        // fixed activation tile drawn once in both ACTS modes, so per-trace draws match
        for (i = 0; i < IF_DEPTH; i = i + 1) fix_a[i] = rand_i8(0);

        // public per-layer constants, identical in both groups
        for (c = 0; c < COLS; c = c + 1) begin
            bias_flat[c*BW +: BW]  = 32'sd137;
            m0_flat[c*MW +: MW]    = 16'sh4E8B;
            shift_flat[c*SW +: SW] = 6'd22;
        end

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});

        reset_n = 0; start = 0; if_wr_en = 0; fl_wr_en = 0;
        if_wr_addr = 0; fl_wr_addr = 0; if_wr_data = 0; fl_wr_data = 0;
        repeat (6) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (40) @(posedge clk);

        // calibration tile (untriggered, no PRNG draws)
        for (i = 0; i < FL_DEPTH; i = i + 1) cur_w[i] = fix_w[i];
        for (i = 0; i < IF_DEPTH; i = i + 1) act[i]   = fix_a[i];
        load_and_start;
        k_done = -1; k_rng = -1; k = -1;
        for (cyc = 0; cyc < 600 && (k_done < 0 || rng_on); cyc = cyc + 1) begin
            if (rng_on) k_rng = cyc;            // rng advances at posedge cyc
            @(posedge clk); #1;
            if (cyc == 0) start = 0;
            if (u_top.stream_start === 1'b1 && k < 0) k = cyc;
            if (int_done && k_done < 0) k_done = cyc;
        end
        if (k < 0) begin $display("[SCA] FATAL: stream_start never seen"); $finish; end
        finish_tile;
        // window end: post_done edge + 2, or last rng step + requant latency + 1
        quiet = k_done + 2;
        if (k_rng >= 0 && k_rng + RQ_LAT + 1 > quiet) quiet = k_rng + RQ_LAT + 1;
        CAPTURE = quiet + IDLE_TAIL;

`ifdef PROT
        sca_open_meta("flexnn_top_protected", CLK_NS, CAPTURE);
`elsif RQ_ONLY
        sca_open_meta("flexnn_top_rq_masked", CLK_NS, CAPTURE);
`elsif ARR_ONLY
        sca_open_meta("flexnn_top_arr_masked", CLK_NS, CAPTURE);
`else
        sca_open_meta("flexnn_top", CLK_NS, CAPTURE);
`endif
        $display("[SCA] accelerator %0dx%0d WAVES=%0d N=%0d ACCW=%0d MW=%0d SW=%0d BW=%0d DOM_REG=%0d NRQ=%0d ACTS=%0s DUMP_TAIL=%0d",
                 ROWS, COLS, WAVES, N, ACCW, MW, SW, BW, DOM_REG, NRQ, ACTS, DUMP_TAIL_I);
        $display("[SCA] capture window %0d cycles from the start pulse = last activity %0d + %0d idle (weight load, stream from %0d, output write at %0d, last rng step at %0d, requant latency %0d)",
                 CAPTURE, quiet - 1, IDLE_TAIL, k, k_done, k_rng, RQ_LAT);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: random weights and activations drawn for both groups and both ACTS modes
            for (i = 0; i < FL_DEPTH; i = i + 1) cur_w[i] = rand_i8(0);
            for (i = 0; i < IF_DEPTH; i = i + 1) act[i]   = rand_i8(0);
            if (!eff)       for (i = 0; i < FL_DEPTH; i = i + 1) cur_w[i] = fix_w[i];
            if (acts_fixed) for (i = 0; i < IF_DEPTH; i = i + 1) act[i]   = fix_a[i];

            // memory writes + start
            load_and_start;

            // capture window
            k_done = -1;
            for (cyc = 0; cyc < CAPTURE; cyc = cyc + 1) begin
                @(posedge clk);
                if (cyc == 0) sca_trace_begin;
                #1;
                if (cyc == 0) start = 0;
                if (int_done && k_done < 0) k_done = cyc;
            end
            @(negedge clk);
            sca_trace_end(grp);
            if (k_done < 0 || k_done + 2 + IDLE_TAIL > CAPTURE) begin
                $display("[SCA] FATAL: trace %0d finished at cycle %0d, outside the %0d-cycle window",
                         t, k_done, CAPTURE);
                $finish;
            end

            // let the run finish, untriggered
            finish_tile;

            if (t % 200 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
