`timescale 1ns/1ps
//=====================================================================
// tb_systolic_array_actlink_masked.sv -- systolic_array_actlink_masked
//
// Compile (from protected_designs/sim):
//   iverilog -g2012 -o arr_link.vvp ../../source/multiplier.sv \
//     ../../source/processing_element.sv ../../source/systolic_array.sv \
//     ../source/systolic_array_actlink_masked.sv ../source/act_masker.sv \
//     tb_systolic_array_actlink_masked.sv
//   vvp arr_link.vvp [+NTRIALS=<n>] [+MASK_EN=0|1]
//
// The REAL baseline systolic_array is the reference. Same stimulus into
// both (the DUT uses the unmodified baseline processing_element); every cycle psum_out, valid_sum_out, act_out, valid_act_out must be
// bit-identical. Also checks the link shares are really shares:
//   mask_en=1: east-link share1 differs from the plaintext activation in
//              >75% of cycles
//   mask_en=0: share0 == 0 and share1 == plaintext on the first link.
// Directed corner weights/activations, then random stream with random
// valid and random wt_load pulses.
//=====================================================================
module tb_systolic_array_actlink_masked;
    localparam N = 8, ACCW = 32, ROWS = 4, COLS = 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                    reset_n, wt_load, mask_en;
    reg  [COLS*N-1:0]      wt_flat;
    reg  [ROWS-1:0]        valid_act_in;
    reg  [ROWS*N-1:0]      act_flat;
    reg  [COLS*ACCW-1:0]   psum_flat;

    wire [COLS*ACCW-1:0] ref_ps, dut_ps;
    wire [COLS-1:0]      ref_vs, dut_vs;
    wire [ROWS*N-1:0]    ref_ao, dut_ao;
    wire [ROWS-1:0]      ref_va, dut_va;

    systolic_array #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_ref (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat), .psum_flat(psum_flat),
        .psum_out(ref_ps), .valid_sum_out(ref_vs), .act_out(ref_ao), .valid_act_out(ref_va));

    systolic_array_actlink_masked #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS),
                                    .MASK_SEED(64'd7)) dut (
        .clk(clk), .reset_n(reset_n), .mask_en(mask_en), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat), .psum_flat(psum_flat),
        .psum_out(dut_ps), .valid_sum_out(dut_vs), .act_out(dut_ao), .valid_act_out(dut_va));

    integer ntrials, errors, cyc, i, k;
    integer n_sample, n_diff, n_share0_bad, n_share1_bad;
    reg [31:0] rnd;
    reg signed [N-1:0] a_plain;

    function [N-1:0] pick8(input integer sel);
        case (sel % 6)
            0: pick8 = 8'sd0;   1: pick8 = 8'sd127; 2: pick8 = -8'sd128;
            3: pick8 = -8'sd1;  4: pick8 = 8'sd1;   default: pick8 = $random;
        endcase
    endfunction

    // first-link plaintext check (row r, link into column 1 is one cycle old)
    reg [ROWS*N-1:0] act_d1;
    always @(posedge clk) act_d1 <= act_flat;

    always @(negedge clk) if (reset_n) begin
        if (dut_ps !== ref_ps || dut_vs !== ref_vs || dut_ao !== ref_ao || dut_va !== ref_va) begin
            errors = errors + 1;
            if (errors < 10)
                $display("[ARRL] MISMATCH t=%0t ps %h/%h vs %b/%b ao %h/%h va %b/%b",
                         $time, dut_ps, ref_ps, dut_vs, ref_vs, dut_ao, ref_ao, dut_va, ref_va);
        end
    end

    // share sanity on row 0, link into column 0 PE output register
    genvar gr;
    wire [N-1:0] s0 = dut.g_row[0].g_lnk[1].g_next.u_link.a0_q[N-1:0];
    wire [N-1:0] s1 = dut.g_row[0].g_lnk[1].g_next.u_link.a1_q[N-1:0];
    always @(negedge clk) if (reset_n && cyc > 4) begin
        n_sample = n_sample + 1;
        a_plain  = s0 + s1;
        if (a_plain !== act_d1[N-1:0]) n_share0_bad = n_share0_bad + 1;   // recombination
        if (s1 !== act_d1[N-1:0]) n_diff = n_diff + 1;
        if (!mask_en && (s0 !== 8'd0 || s1 !== act_d1[N-1:0])) n_share1_bad = n_share1_bad + 1;
    end

    task step;
        begin
            @(negedge clk);
            cyc = cyc + 1;
        end
    endtask

    initial begin
        if (!$value$plusargs("NTRIALS=%d", ntrials)) ntrials = 3000;
        if (!$value$plusargs("MASK_EN=%d", k)) k = 1;
        mask_en = (k != 0);
        errors = 0; cyc = 0; n_sample = 0; n_diff = 0; n_share0_bad = 0; n_share1_bad = 0;
        reset_n = 0; wt_load = 0; wt_flat = 0; valid_act_in = 0; act_flat = 0; psum_flat = 0;
        $display("[ARRL] %0dx%0d mask_en=%0d, directed corners then %0d random cycles",
                 ROWS, COLS, mask_en, ntrials);
        repeat (3) @(negedge clk);
        reset_n = 1;

        // directed: load corner weights, stream corner activations
        for (i = 0; i < ROWS; i = i + 1) begin
            step; wt_load = 1;
            for (k = 0; k < COLS; k = k + 1) wt_flat[k*N +: N] = pick8(i + k);
        end
        step; wt_load = 0;
        for (i = 0; i < 24; i = i + 1) begin
            step; valid_act_in = {ROWS{1'b1}};
            for (k = 0; k < ROWS; k = k + 1) act_flat[k*N +: N] = pick8(i + k);
        end

        // random
        for (i = 0; i < ntrials; i = i + 1) begin
            step;
            rnd = $random;
            wt_load = (rnd[7:0] < 8'd12);
            for (k = 0; k < COLS; k = k + 1) wt_flat[k*N +: N] = $random;
            valid_act_in = $random;
            for (k = 0; k < ROWS; k = k + 1) act_flat[k*N +: N] = $random;
            for (k = 0; k < COLS; k = k + 1) psum_flat[k*ACCW +: ACCW] = 0;
        end
        step; step; step; step; step; step;

        $display("[ARRL] cycles=%0d mismatches=%0d  shares: samples=%0d recombine_bad=%0d share1!=plain in %0d",
                 cyc, errors, n_sample, n_share0_bad, n_diff);
        if (mask_en && n_diff < (n_sample*3)/4) begin
            errors = errors + 1;
            $display("[ARRL] FAIL: share1 equals plaintext too often (masking inactive?)");
        end
        if (!mask_en && n_share1_bad != 0) begin
            errors = errors + 1;
            $display("[ARRL] FAIL: mask_en=0 but share0/share1 not (0, A)");
        end
        if (n_share0_bad != 0) errors = errors + 1;
        if (errors == 0) $display("PASS"); else $display("FAIL (%0d)", errors);
        $finish;
    end
endmodule
