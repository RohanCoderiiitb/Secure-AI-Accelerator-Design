`timescale 1ns/1ps
//=====================================================================
// tb_accel_func.sv -- end-to-end functional check of the protected
//                     accelerator against the unprotected one
//
//   u_ref : flexnn_top            (source/top.sv)
//   u_dut : flexnn_top_protected  (both masked, default)
//           flexnn_top_rq_masked  (-DRQ_ONLY)   flexnn_top_arr_masked (-DARR_ONLY)
//
// Per test: random activations and weights are written through the
// global-buffer ports, layer constants (bias, m0, shift, activation mode,
// clamp, leaky shift) are randomised, both accelerators are started, and
// after both report done every output-buffer entry is read back and
// compared. Also reports start->done cycles of both designs.
//
//   vvp ... [+NTEST=150] [+SEED=1]
//=====================================================================
module tb_accel_func;
    parameter N = 8, ACCW = 32, ROWS = 4, COLS = 4, WAVES = 4;
    parameter MW = 32, SW = 6, POOL_LEN = 1;
    parameter DOM_REG = 1;
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n, start;
    reg if_wr_en, fl_wr_en;
    reg [IF_ADDR_W-1:0] if_wr_addr;
    reg [FL_ADDR_W-1:0] fl_wr_addr;
    reg [N-1:0] if_wr_data, fl_wr_data;
    reg [COLS*ACCW-1:0] bias_flat;
    reg [COLS*MW-1:0]   m0_flat;
    reg [COLS*SW-1:0]   shift_flat;
    reg [1:0]           act_mode;
    reg signed [N-1:0]  act_clamp_high;
    reg [2:0]           act_leaky_shift;
    reg [CW-1:0]        pool_win_len;
    reg [COLS-1:0]           of_rd_en;
    reg [COLS*OF_ADDR_W-1:0] of_rd_addr_flat;

    wire done_r, done_d, acd_r, acd_d;
    wire [COLS-1:0] ovf_r, ovf_d, sat_r, sat_d;
    wire [COLS*N-1:0] of_r, of_d;

    flexnn_top #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)) u_ref (
        .clk(clk), .reset_n(reset_n), .start(start), .done(done_r), .array_compute_done(acd_r),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_r), .requant_sat_flat(sat_r),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_r));

`ifdef RQ_ONLY
    flexnn_top_rq_masked #(
`elsif ARR_ONLY
    flexnn_top_arr_masked #(
`else
    flexnn_top_protected #(
`endif.N(N), .ACCW(ACCW), .ARRAY_ROWS(ROWS), .ARRAY_COLS(COLS), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)`ifndef ARR_ONLY , .DOM_REG(DOM_REG)`endif) u_dut (
        .clk(clk), .reset_n(reset_n), .start(start), .done(done_d), .array_compute_done(acd_d),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_d), .requant_sat_flat(sat_d),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_d));

    integer NTEST, SEED, seed, t, i, c, k;
    integer errors = 0, compared = 0, nonsat = 0;
    integer cyc = 0, t0, tr, td, cyc_r = 0, cyc_d = 0;
    reg got_r, got_d;
    always @(posedge clk) cyc <= cyc + 1;
    always @(posedge clk) begin
        if (done_r) begin got_r <= 1'b1; tr <= cyc; end
        if (done_d) begin got_d <= 1'b1; td <= cyc; end
    end

    task write_mems;
        begin
            for (i = 0; i < IF_DEPTH; i = i + 1) begin
                @(negedge clk); if_wr_en = 1; if_wr_addr = i; if_wr_data = $random(seed);
            end
            @(negedge clk); if_wr_en = 0;
            for (i = 0; i < FL_DEPTH; i = i + 1) begin
                @(negedge clk); fl_wr_en = 1; fl_wr_addr = i; fl_wr_data = $random(seed);
            end
            @(negedge clk); fl_wr_en = 0;
        end
    endtask

    initial begin
        if (!$value$plusargs("NTEST=%d", NTEST)) NTEST = 150;
        if (!$value$plusargs("SEED=%d",  SEED))  SEED  = 1;
        seed = SEED;
        reset_n = 0; start = 0; if_wr_en = 0; fl_wr_en = 0;
        if_wr_addr = 0; fl_wr_addr = 0; if_wr_data = 0; fl_wr_data = 0;
        bias_flat = 0; m0_flat = 0; shift_flat = 0; act_mode = 0;
        act_clamp_high = 8'sd100; act_leaky_shift = 3'd2; pool_win_len = 1;
        of_rd_en = 0; of_rd_addr_flat = 0;
        repeat (6) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (40) @(posedge clk);

        for (t = 0; t < NTEST; t = t + 1) begin
            write_mems;
            for (c = 0; c < COLS; c = c + 1) begin
                bias_flat[c*ACCW +: ACCW] = $random(seed) % 4096;
                m0_flat[c*MW +: MW]       = {1'b0, 1'b1, 30'h0} | ($random(seed) & 32'h3FFF_FFFF);
                shift_flat[c*SW +: SW]    = (($random(seed) & 7) == 0) ? ($unsigned($random(seed)) % 30)
                                                                       : 32 + ($unsigned($random(seed)) % 9);
            end
            act_mode        = $random(seed);
            act_clamp_high  = 8'sd20 + ($unsigned($random(seed)) % 100);
            act_leaky_shift = $random(seed);

            got_r = 0; got_d = 0;
            @(negedge clk); start = 1; t0 = cyc;
            @(negedge clk); start = 0;
            k = 0;
            while (!(got_r && got_d) && k < 2000) begin @(negedge clk); k = k + 1; end
            if (!(got_r && got_d)) begin
                errors = errors + 1;
                $display("[FAIL] test %0d: done missing (ref=%0d prot=%0d)", t, got_r, got_d);
            end
            cyc_r = tr - t0; cyc_d = td - t0;
            repeat (3) @(negedge clk);

            // read back every output-buffer entry of both designs
            for (i = 0; i < OF_DEPTH; i = i + 1) begin
                @(negedge clk);
                of_rd_en = {COLS{1'b1}};
                for (c = 0; c < COLS; c = c + 1) of_rd_addr_flat[c*OF_ADDR_W +: OF_ADDR_W] = i;
                @(negedge clk);
                of_rd_en = 0;
                for (c = 0; c < COLS; c = c + 1) begin
                    compared = compared + 1;
                    if (of_r[c*N +: N] != 8'h7F && of_r[c*N +: N] != 8'h80 && of_r[c*N +: N] != 8'h00)
                        nonsat = nonsat + 1;
                    if (of_r[c*N +: N] !== of_d[c*N +: N]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("[FAIL] test %0d col %0d entry %0d: ref=%h prot=%h (shift=%0d mode=%0d)",
                                     t, c, i, of_r[c*N +: N], of_d[c*N +: N],
                                     shift_flat[c*SW +: SW], act_mode);
                    end
                end
            end
            if (ovf_r !== ovf_d) begin
                errors = errors + 1;
                $display("[FAIL] test %0d: psum overflow flags differ", t);
            end
        end

        $display("");
        $display("============ full accelerator: protected vs unprotected ============");
        $display("  tests %0d, output values compared %0d (%0d not saturated/zero)", NTEST, compared, nonsat);
        $display("  start -> done : unprotected %0d cycles, protected %0d cycles (+%0d)",
                 cyc_r, cyc_d, cyc_d - cyc_r);
        if (errors == 0) $display("  [ACCEL] PASS: every output identical");
        else             $display("  [ACCEL] FAIL: %0d mismatches", errors);
        $display("=====================================================================");
        $finish;
    end
endmodule
