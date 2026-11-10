`timescale 1ns/1ps
// Functional check: protected vs unprotected accelerator vs behavioural model (-DRQ_ONLY / -DARR_ONLY select the build)
module tb_accel_func;
    parameter N = 8, ACCW = 19, ROWS = 5, COLS = 5, WAVES = 4;
    parameter MW = 16, SW = 6, BW = 32, POOL_LEN = 1;
    parameter DOM_REG = 1;
    parameter NRQ = 1;                     // shared masked requantizer cores (evaluated configuration)
    localparam IF_DEPTH  = ROWS * WAVES;
    localparam FL_DEPTH  = ROWS * COLS;
    localparam OF_DEPTH  = WAVES / POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH <= 1) ? 1 : $clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN <= 1) ? 1 : $clog2(POOL_LEN+1);
    localparam RD_LAT    = 3;              // of_rd_en pin -> of_rd_data pin

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n, start_r, start_d;
    reg if_wr_en, fl_wr_en;
    reg [IF_ADDR_W-1:0] if_wr_addr;
    reg [FL_ADDR_W-1:0] fl_wr_addr;
    reg [N-1:0] if_wr_data, fl_wr_data;
    reg [COLS*BW-1:0]   bias_flat;
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
                 .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN)) u_ref (
        .clk(clk), .reset_n(reset_n), .start(start_r), .done(done_r), .array_compute_done(acd_r),
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
                 .MW(MW), .SW(SW), .BW(BW), .POOL_LEN(POOL_LEN)`ifndef ARR_ONLY , .DOM_REG(DOM_REG), .NRQ(NRQ)`endif) u_dut (
        .clk(clk), .reset_n(reset_n), .start(start_d), .done(done_d), .array_compute_done(acd_d),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_d), .requant_sat_flat(sat_d),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_d));

    integer NTEST, NBURST, SEED, seed, t, i, c, k, r;
    integer errors = 0, merrors = 0, compared = 0, nonsat = 0;
    integer cyc = 0, t0, tr, td, cyc_r = 0, cyc_d = 0;
    integer nd_r, nd_d, tfirst_r, tlast_r, tfirst_d, tlast_d;
    real    per_r, per_d;
    reg got_r, got_d;
    always @(posedge clk) cyc <= cyc + 1;
    always @(posedge clk) begin
        if (done_r) begin got_r <= 1'b1; tr <= cyc; end
        if (done_d) begin got_d <= 1'b1; td <= cyc; end
    end

    // behavioural model
    reg signed [N-1:0] ifm [0:IF_DEPTH-1];          // IF_GB[r*WAVES + k] = A[k][r]
    reg signed [N-1:0] flm [0:FL_DEPTH-1];          // FL_GB[r*COLS + c]  = W[r][c]
    reg        [N-1:0] gold [0:COLS-1][0:OF_DEPTH-1];

    function [N-1:0] model_out;
        input integer cc, kk;
        integer rr;
        reg signed [63:0] acc, v, rnd;
        reg signed [N-1:0] q;
        reg signed [BW-1:0] bias;
        reg signed [MW-1:0] m0;
        reg [SW-1:0] sh;
        begin
            acc = 0;
            for (rr = 0; rr < ROWS; rr = rr + 1) acc = acc + ifm[rr*WAVES + kk] * flm[rr*COLS + cc];
            bias = bias_flat[cc*BW +: BW];
            m0   = m0_flat[cc*MW +: MW];
            sh   = shift_flat[cc*SW +: SW];
            v    = (acc + bias) * m0;
            rnd  = (sh == 0) ? 64'sd0 : (64'sd1 <<< (sh - 1));
            v    = (v + rnd) >>> sh;
            q    = (v > 127) ? 8'sd127 : ((v < -128) ? -8'sd128 : v[N-1:0]);
            case (act_mode)
                2'd0: model_out = q;
                2'd1: model_out = q[N-1] ? 8'd0 : q;
                2'd2: model_out = q[N-1] ? 8'd0 : ((q > act_clamp_high) ? act_clamp_high : q);
                2'd3: model_out = q[N-1] ? (q >>> act_leaky_shift) : q;
            endcase
        end
    endfunction

    task write_mems;
        begin
            for (i = 0; i < IF_DEPTH; i = i + 1) begin
                @(negedge clk); if_wr_en = 1; if_wr_addr = i; if_wr_data = $random(seed); ifm[i] = if_wr_data;
            end
            @(negedge clk); if_wr_en = 0;
            for (i = 0; i < FL_DEPTH; i = i + 1) begin
                @(negedge clk); fl_wr_en = 1; fl_wr_addr = i; fl_wr_data = $random(seed); flm[i] = fl_wr_data;
            end
            @(negedge clk); fl_wr_en = 0;
        end
    endtask

    task set_constants;
        reg [31:0] m32;
        begin
            for (c = 0; c < COLS; c = c + 1) begin
                bias_flat[c*BW +: BW]  = $random(seed) % 4096;
                m32                    = {1'b0, 1'b1, 30'h0} | ($random(seed) & 32'h3FFF_FFFF);
                m0_flat[c*MW +: MW]    = m32[31:16];                 // top 16 bits of the Q0.31 multiplier
                shift_flat[c*SW +: SW] = (($random(seed) & 7) == 0) ? ($unsigned($random(seed)) % 14)
                                                                     : 16 + ($unsigned($random(seed)) % 9);
            end
            act_mode        = $random(seed);
            act_clamp_high  = 8'sd20 + ($unsigned($random(seed)) % 100);
            act_leaky_shift = $random(seed);
            for (c = 0; c < COLS; c = c + 1)
                for (k = 0; k < OF_DEPTH; k = k + 1) gold[c][k] = model_out(c, k);
        end
    endtask

    // read every output-buffer entry of both designs and compare
    task check_outputs;
        input integer tag;
        begin
            for (i = 0; i < OF_DEPTH; i = i + 1) begin
                @(negedge clk);
                of_rd_en = {COLS{1'b1}};
                for (c = 0; c < COLS; c = c + 1) of_rd_addr_flat[c*OF_ADDR_W +: OF_ADDR_W] = i;
                @(negedge clk);
                of_rd_en = 0;
                repeat (RD_LAT - 1) @(negedge clk);
                for (c = 0; c < COLS; c = c + 1) begin
                    compared = compared + 1;
                    if (of_r[c*N +: N] != 8'h7F && of_r[c*N +: N] != 8'h80 && of_r[c*N +: N] != 8'h00)
                        nonsat = nonsat + 1;
                    if (of_r[c*N +: N] !== of_d[c*N +: N]) begin
                        errors = errors + 1;
                        if (errors <= 10)
                            $display("[FAIL] test %0d col %0d entry %0d: ref=%h prot=%h (shift=%0d mode=%0d)",
                                     tag, c, i, of_r[c*N +: N], of_d[c*N +: N],
                                     shift_flat[c*SW +: SW], act_mode);
                    end
                    if (of_r[c*N +: N] !== gold[c][i]) begin
                        merrors = merrors + 1;
                        if (merrors <= 10)
                            $display("[FAIL] test %0d col %0d entry %0d: ref=%h model=%h (shift=%0d mode=%0d)",
                                     tag, c, i, of_r[c*N +: N], gold[c][i], shift_flat[c*SW +: SW], act_mode);
                    end
                end
            end
        end
    endtask

    // NBURST back-to-back tiles on one design
    task burst;
        input sel;                               // 0 = ref, 1 = dut
        output integer ndone, tfirst, tlast;
        integer nst, guard;
        begin
            ndone = 0; nst = 0; guard = 0; tfirst = 0; tlast = 0;
            while ((ndone < NBURST) && guard < 4000) begin
                @(negedge clk);
                guard = guard + 1;
                if (sel) start_d = 0; else start_r = 0;
                if (nst == 0 || (nst < NBURST && (sel ? acd_d : acd_r))) begin
                    if (sel) start_d = 1; else start_r = 1;
                    nst = nst + 1;
                end
                if (sel ? done_d : done_r) begin
                    if (ndone == 0) tfirst = cyc;
                    tlast = cyc;
                    ndone = ndone + 1;
                end
            end
            @(negedge clk); start_r = 0; start_d = 0;
            if (ndone != NBURST) begin
                errors = errors + 1;
                $display("[FAIL] burst on %0s: %0d of %0d tiles done", sel ? "prot" : "ref", ndone, NBURST);
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("NTEST=%d",  NTEST))  NTEST  = 150;
        if (!$value$plusargs("NBURST=%d", NBURST)) NBURST = 8;
        if (!$value$plusargs("SEED=%d",   SEED))   SEED   = 1;
        seed = SEED;
        reset_n = 0; start_r = 0; start_d = 0; if_wr_en = 0; fl_wr_en = 0;
        if_wr_addr = 0; fl_wr_addr = 0; if_wr_data = 0; fl_wr_data = 0;
        bias_flat = 0; m0_flat = 0; shift_flat = 0; act_mode = 0;
        act_clamp_high = 8'sd100; act_leaky_shift = 3'd2; pool_win_len = 1;
        of_rd_en = 0; of_rd_addr_flat = 0;
        repeat (6) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (40) @(posedge clk);

        // phase 1
        for (t = 0; t < NTEST; t = t + 1) begin
            write_mems;
            set_constants;
            got_r = 0; got_d = 0;
            @(negedge clk); start_r = 1; start_d = 1; t0 = cyc;
            @(negedge clk); start_r = 0; start_d = 0;
            k = 0;
            while (!(got_r && got_d) && k < 2000) begin @(negedge clk); k = k + 1; end
            if (!(got_r && got_d)) begin
                errors = errors + 1;
                $display("[FAIL] test %0d: done missing (ref=%0d prot=%0d)", t, got_r, got_d);
            end
            cyc_r = tr - t0; cyc_d = td - t0;
            repeat (3) @(negedge clk);
            check_outputs(t);
            if (ovf_r !== ovf_d) begin
                errors = errors + 1;
                $display("[FAIL] test %0d: psum overflow flags differ", t);
            end
        end

        // phase 2
        write_mems;
        set_constants;
        burst(1'b0, nd_r, tfirst_r, tlast_r);
        burst(1'b1, nd_d, tfirst_d, tlast_d);
        repeat (3) @(negedge clk);
        check_outputs(NTEST);
        per_r = (tlast_r - tfirst_r) * 1.0 / (NBURST - 1);
        per_d = (tlast_d - tfirst_d) * 1.0 / (NBURST - 1);

        $display("");
        $display("============ full accelerator: protected vs unprotected ============");
`ifdef RQ_ONLY
        $display("  DUT flexnn_top_rq_masked  NRQ=%0d", NRQ);
`elsif ARR_ONLY
        $display("  DUT flexnn_top_arr_masked");
`else
        $display("  DUT flexnn_top_protected  NRQ=%0d", NRQ);
`endif
        $display("  tests %0d + %0d back-to-back tiles, output values compared %0d (%0d not saturated/zero)",
                 NTEST, NBURST, compared, nonsat);
        $display("  start -> done : unprotected %0d cycles, protected %0d cycles (+%0d)",
                 cyc_r, cyc_d, cyc_d - cyc_r);
        $display("  back-to-back  : unprotected %0.1f cycles/tile, protected %0.1f cycles/tile",
                 per_r, per_d);
        if (merrors == 0) $display("  [ACCEL] PASS: unprotected outputs identical to the behavioural model");
        else              $display("  [ACCEL] FAIL: %0d mismatches against the behavioural model", merrors);
        if (errors == 0) $display("  [ACCEL] PASS: every output identical");
        else             $display("  [ACCEL] FAIL: %0d mismatches", errors);
        $display("=====================================================================");
        $finish;
    end
endmodule
