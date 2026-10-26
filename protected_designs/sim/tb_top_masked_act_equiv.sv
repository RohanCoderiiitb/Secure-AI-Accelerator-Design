`timescale 1ns/1ps
//=====================================================================
// tb_top_masked_act_equiv.sv -- integration gate:
//   flexnn_top (baseline, untouched)  vs  top_masked_act
// Identical random IF / FL contents and requantize configuration; after
// `start` both run to `done`, then every OF word of every column is read
// back and compared. Exercises the real load_controller, the activation
// masker at the array's west boundary and the TEMPORARY recombination
// before the unmasked psum_accum/requantize/activation/maxpool tail.
//   +RUNS=<n> (default 2)   +MASK_EN=0|1 (default 1)   +MAXCYC=<n>
// 4x4 array by default (parameters below) to keep simulation time sane.
//
// Compile (from protected_designs/sim). masked_wt_multiplier.sv redefines
// half_adder/full_adder that source/multiplier.sv already provides, so the
// duplicates are stripped into a scratch copy first:
//   sed '/^module half_adder/,/^endmodule/d;/^module full_adder/,/^endmodule/d' \
//       ../source/masked_wt_multiplier.sv > share_mult_only.sv
//   iverilog -g2012 -I ../../security_analyses/unprotected -o top_act.vvp \
//       tb_top_masked_act_equiv.sv ../../source/*.sv share_mult_only.sv \
//       ../source/processing_element_masked_act.sv \
//       ../source/systolic_array_masked_act.sv ../source/act_masker.sv \
//       ../source/top_masked_act.sv
//   vvp top_act.vvp [+MASK_EN=0] [+RUNS=n]
//=====================================================================
module tb_top_masked_act_equiv;
    localparam N = 8, ACCW = 32, AR = 4, AC = 4, WAVES = 4, MW = 32, SW = 6, POOL = 1;
    localparam IF_DEPTH = AR*WAVES, FL_DEPTH = AR*AC, OF_DEPTH = WAVES/POOL;
    localparam IF_AW = $clog2(IF_DEPTH), FL_AW = $clog2(FL_DEPTH), OF_AW = (OF_DEPTH<=1)?1:$clog2(OF_DEPTH);
    localparam CW = (POOL <= 1) ? 1 : $clog2(POOL+1);
    localparam real CLK_NS = 10.0;

    reg clk = 1'b0;
    always #(CLK_NS/2.0) clk = ~clk;

    reg reset_n, start, mask_en;
    reg                 if_wr_en, fl_wr_en;
    reg [IF_AW-1:0]     if_wr_addr;
    reg [FL_AW-1:0]     fl_wr_addr;
    reg [N-1:0]         if_wr_data, fl_wr_data;
    reg [AC*ACCW-1:0]   bias_flat;
    reg [AC*MW-1:0]     m0_flat;
    reg [AC*SW-1:0]     shift_flat;
    reg [1:0]           act_mode;
    reg signed [N-1:0]  act_clamp_high;
    reg [2:0]           act_leaky_shift;
    reg [CW-1:0]        pool_win_len;
    reg [AC-1:0]            of_rd_en;
    reg [AC*OF_AW-1:0]      of_rd_addr_flat;

    wire done_b, acd_b, done_m, acd_m;
    wire [AC-1:0] ovf_b, sat_b, ovf_m, sat_m;
    wire [AC*N-1:0] of_b, of_m;

    flexnn_top #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(AR), .ARRAY_COLS(AC), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .POOL_LEN(POOL)) u_b (
        .clk(clk), .reset_n(reset_n), .start(start), .done(done_b), .array_compute_done(acd_b),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_b), .requant_sat_flat(sat_b),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_b));

    top_masked_act #(.N(N), .ACCW(ACCW), .ARRAY_ROWS(AR), .ARRAY_COLS(AC), .WAVES(WAVES),
                 .MW(MW), .SW(SW), .POOL_LEN(POOL)) u_m (
        .clk(clk), .reset_n(reset_n), .start(start), .mask_en(mask_en), .done(done_m),
        .array_compute_done(acd_m),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len), .psum_ovf_flat(ovf_m), .requant_sat_flat(sat_m),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_m));

    `include "sca_capture.vh"

    integer RQSHIFT, RUNS, MAXCYC, mc, run, i, a, c, cyc, errors, words, nonzero, ovf_seen;
    reg got_b, got_m;

    initial begin
        sca_get_config("top_act_equiv");
        if (!$value$plusargs("RUNS=%d",   RUNS))   RUNS   = 2;
        if (!$value$plusargs("MAXCYC=%d", MAXCYC)) MAXCYC = 3000;
        if (!$value$plusargs("RQSHIFT=%d", RQSHIFT)) RQSHIFT = 38;   // m0=2^30: out ~= acc/512, unsaturated
        if (!$value$plusargs("MASK_EN=%d", mc))    mc     = 1;
        mask_en = (mc != 0);
        errors = 0; words = 0; nonzero = 0; ovf_seen = 0;
        reset_n = 0; start = 0; if_wr_en = 0; fl_wr_en = 0; if_wr_addr = 0; fl_wr_addr = 0;
        if_wr_data = 0; fl_wr_data = 0; of_rd_en = 0; of_rd_addr_flat = 0;
        act_mode = 0; act_clamp_high = 127; act_leaky_shift = 0; pool_win_len = 1;
        bias_flat = 0; m0_flat = 0; shift_flat = 0;
        repeat (4) @(posedge clk);
        reset_n = 1;
        repeat (2) @(posedge clk);
        $display("[TOP] %0dx%0d  mask_en=%0d  runs=%0d (activations masked)", AR, AC, mask_en, RUNS);

        for (run = 0; run < RUNS; run = run + 1) begin
            // ---- fill IF and FL buffers (identical for both tops) ----
            for (i = 0; i < IF_DEPTH; i = i + 1) begin
                @(negedge clk); if_wr_en = 1; if_wr_addr = i;
                if_wr_data = (run == 0 && i < 4) ? -128 : rand_i8(0);   // include -128 activations
            end
            @(negedge clk); if_wr_en = 0;
            for (i = 0; i < FL_DEPTH; i = i + 1) begin
                @(negedge clk); fl_wr_en = 1; fl_wr_addr = i;
                fl_wr_data = (run == 0 && i < 4) ? -128 : rand_i8(0);
            end
            @(negedge clk); fl_wr_en = 0;
            // ---- requantize config: moderate gain so results are not all saturated ----
            for (c = 0; c < AC; c = c + 1) begin
                bias_flat[c*ACCW +: ACCW] = $signed(rand_word(10)) - 512;
                m0_flat[c*MW +: MW]       = 32'h4000_0000;
                shift_flat[c*SW +: SW]    = RQSHIFT;
            end
            // ---- go ----
            @(negedge clk); start = 1;
            @(negedge clk); start = 0;
            got_b = 0; got_m = 0; cyc = 0;
            while (!(got_b && got_m) && cyc < MAXCYC) begin
                @(posedge clk); cyc = cyc + 1;
                if (done_b) got_b = 1;
                if (done_m) got_m = 1;
            end
            if (!(got_b && got_m)) begin
                $display("[TOP] FATAL: done not reached (baseline=%0d masked=%0d) after %0d cycles", got_b, got_m, cyc);
                $display("FAIL"); $finish;
            end
            repeat (3) @(posedge clk);
            // ---- read back every OF word ----
            for (a = 0; a < OF_DEPTH; a = a + 1) begin
                @(negedge clk);
                of_rd_en = {AC{1'b1}};
                for (c = 0; c < AC; c = c + 1) of_rd_addr_flat[c*OF_AW +: OF_AW] = a;
                @(posedge clk); @(posedge clk); #1;
                words = words + AC;
                if (of_b !== of_m) begin
                    errors = errors + 1;
                    $display("[TOP] OF MISMATCH run %0d addr %0d: base=%h masked=%h", run, a, of_b, of_m);
                end
                if (of_b !== {AC*N{1'b0}}) nonzero = nonzero + 1;
                if (|ovf_b || |sat_b) ovf_seen = ovf_seen + 1;
                if (ovf_b !== ovf_m || sat_b !== sat_m) begin
                    errors = errors + 1;
                    $display("[TOP] FLAG MISMATCH run %0d addr %0d", run, a);
                end
            end
            @(negedge clk); of_rd_en = 0;
            repeat (4) @(posedge clk);
        end
        $display("[TOP] runs=%0d words compared=%0d  nonzero OF rows=%0d  ovf/sat flags seen=%0d  mismatches=%0d  (done after %0d cycles)",
                 RUNS, words, nonzero, ovf_seen, errors, cyc);
        if (errors == 0 && nonzero > 0) $display("PASS");
        else if (errors == 0)           $display("FAIL (outputs all zero: test is not exercising the datapath)");
        else                            $display("FAIL");
        $finish;
    end
endmodule
