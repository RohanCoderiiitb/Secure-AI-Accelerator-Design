`timescale 1ns/1ps
//=====================================================================
// tb_systolic_array_masked_act.sv -- systolic_array_masked_act
//
// Compile (from protected_designs/sim):
//   iverilog -g2012 -o arr_act.vvp ../source/masked_wt_multiplier.sv \
//     ../source/processing_element_masked_act.sv ../source/systolic_array_masked_act.sv \
//     ../source/act_masker.sv tb_systolic_array_masked_act.sv
//   vvp arr_act.vvp [+NTRIALS=<n>] [+MASK_EN=0|1]
//
// The plaintext stream (weights + activations) is fed to
//   (a) a behavioural reference array (same registers/latencies as the
//       baseline systolic_array, signed arithmetic, ACCW = 32) and
//   (b) act_masker -> systolic_array_masked_act
// and, EVERY cycle, the DUT outputs are checked against the reference:
//   psum0_out + psum1_out == ref psum_out        (per column)
//   valid_sum_out, valid_act_out                  identical
//   act0_out + act1_out   == sext(ref act_out)    (per row)
// Weight loads are done by shifting ROWS wt_load pulses as in the
// baseline. Directed corner weights/activations, then random streams
// with random valid and random wt_load pulses.
// With +MASK_EN=0 additionally asserts share 0 of psum/act is zero.
//=====================================================================
module tb_systolic_array_masked_act;
    localparam N = 8, SW = 32, ROWS = 4, COLS = 3;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                  reset_n, wt_load, mask_en;
    reg [COLS*N-1:0]     wt_flat;
    reg [ROWS-1:0]       valid_act_in;
    reg [ROWS*N-1:0]     act_flat;

    // ---------------- reference: behavioural baseline array ----------------
    reg signed [N-1:0]  r_wt  [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0]  r_act [0:ROWS-1][0:COLS-1];
    reg                 r_vld [0:ROWS-1][0:COLS-1];
    reg signed [SW-1:0] r_ps  [0:ROWS-1][0:COLS-1];
    integer rr, cc;
    always @(posedge clk) begin
        if (!reset_n) begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    r_wt[rr][cc] <= 0; r_act[rr][cc] <= 0;
                    r_vld[rr][cc] <= 0; r_ps[rr][cc] <= 0;
                end
        end else begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    if (wt_load)
                        r_wt[rr][cc] <= (rr == 0) ? $signed(wt_flat[cc*N +: N]) : r_wt[rr-1][cc];
                    r_act[rr][cc] <= (cc == 0) ? $signed(act_flat[rr*N +: N]) : r_act[rr][cc-1];
                    r_vld[rr][cc] <= (cc == 0) ? valid_act_in[rr] : r_vld[rr][cc-1];
                    r_ps[rr][cc]  <= ((rr == 0) ? 32'sd0 : r_ps[rr-1][cc])
                                     + ((cc == 0) ? $signed(act_flat[rr*N +: N]) : r_act[rr][cc-1]) *
                                       r_wt[rr][cc];
                end
        end
    end

    // ---------------- DUT path ----------------
    wire [ROWS*SW-1:0] a0_flat, a1_flat;
    wire [COLS*SW-1:0] ps0_out, ps1_out;
    wire [COLS-1:0]    vsum;
    wire [ROWS*SW-1:0] ao0, ao1;
    wire [ROWS-1:0]    vact;

    act_masker #(.N(N), .SHARE_W(SW), .ROWS(ROWS), .SEED(64'd7)) u_mask (
        .clk(clk), .reset_n(reset_n), .advance(1'b1), .mask_en(mask_en),
        .act_flat(act_flat), .act0_flat(a0_flat), .act1_flat(a1_flat));

    systolic_array_masked_act #(.N(N), .SHARE_W(SW), .ROWS(ROWS), .COLS(COLS)) dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act0_flat(a0_flat), .act1_flat(a1_flat),
        .psum0_flat({(COLS*SW){1'b0}}), .psum1_flat({(COLS*SW){1'b0}}),
        .psum0_out(ps0_out), .psum1_out(ps1_out), .valid_sum_out(vsum),
        .act0_out(ao0), .act1_out(ao1), .valid_act_out(vact));

    // bottom-row stored weights (checks the weight shift chain)
    wire [COLS*N-1:0] bot_wt;
    genvar gc;
    generate
        for (gc = 0; gc < COLS; gc = gc + 1) begin : g_probe
            assign bot_wt[gc*N +: N] = dut.g_row[ROWS-1].g_col[gc].pe_inst.wt_reg;
        end
    endgenerate

    // ---------------- PRNG ----------------
    reg [63:0] st = 64'h2545F4914F6CDD1D;
    function [63:0] rnd64(input dummy);
        reg [63:0] t;
        begin
            t = st ^ (st >> 12); t = t ^ (t << 25); t = t ^ (t >> 27);
            st = t;
            rnd64 = t * 64'h2545F4914F6CDD1D;
        end
    endfunction

    integer NTRIALS, mc, errors = 0, cycles = 0, i, j, c, r, nonzero = 0;
    reg [SW-1:0] sa, sext_a;

    task check;
        begin
            #1;
            cycles = cycles + 1;
            for (c = 0; c < COLS; c = c + 1) begin
                if ((ps0_out[c*SW +: SW] + ps1_out[c*SW +: SW]) !== r_ps[ROWS-1][c]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH psum col %0d @%0t: %h+%h != %h", c, $time,
                        ps0_out[c*SW +: SW], ps1_out[c*SW +: SW], r_ps[ROWS-1][c]);
                end
                if (vsum[c] !== r_vld[ROWS-1][c]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH valid_sum col %0d @%0t", c, $time);
                end
                if (!mask_en && ps0_out[c*SW +: SW] !== 0) begin
                    errors = errors + 1;
                    if (errors < 10) $display("mask_en=0 but psum0 nonzero @%0t", $time);
                end
                if (r_ps[ROWS-1][c] !== 0) nonzero = nonzero + 1;
            end
            for (r = 0; r < ROWS; r = r + 1) begin
                sext_a = {{(SW-N){r_act[r][COLS-1][N-1]}}, r_act[r][COLS-1]};
                if ((ao0[r*SW +: SW] + ao1[r*SW +: SW]) !== sext_a || vact[r] !== r_vld[r][COLS-1]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH act/valid row %0d @%0t", r, $time);
                end
            end
            // weights propagated down the column: compare bottom row's weights
            for (c = 0; c < COLS; c = c + 1)
                if (bot_wt[c*N +: N] !== r_wt[ROWS-1][c]) begin
                    errors = errors + 1;
                    if (errors < 10) $display("MISMATCH wt col %0d @%0t", c, $time);
                end
        end
    endtask

    task drive(input ld, input [ROWS-1:0] v, input [ROWS*N-1:0] a, input [COLS*N-1:0] w);
        begin
            @(negedge clk);
            wt_load = ld; valid_act_in = v; act_flat = a; wt_flat = w;
            @(posedge clk);
            check;
        end
    endtask

    reg [ROWS*N-1:0] av;
    reg [COLS*N-1:0] wv;
    integer k;

    initial begin
        if (!$value$plusargs("NTRIALS=%d", NTRIALS)) NTRIALS = 3000;
        if (!$value$plusargs("MASK_EN=%d", mc))      mc = 1;
        mask_en = (mc != 0);
        reset_n = 0; wt_load = 0; wt_flat = 0; valid_act_in = 0; act_flat = 0;
        repeat (4) @(posedge clk);
        @(negedge clk); reset_n = 1;
        repeat (2) @(posedge clk);
        $display("[ARR] %0dx%0d mask_en=%0d, directed corners then %0d random cycles", ROWS, COLS, mask_en, NTRIALS);

        // ---- directed: fill the array with extreme weights, stream extreme activations ----
        for (j = 0; j < 4; j = j + 1) begin
            for (k = 0; k < ROWS; k = k + 1) begin
                case (j)
                    0: wv = {COLS{8'h80}};
                    1: wv = {COLS{8'h7F}};
                    2: wv = {COLS{8'hFF}};
                    default: wv = {COLS{8'h01}};
                endcase
                drive(1'b1, 0, 0, wv);
            end
            for (i = 0; i < 4; i = i + 1) begin
                case (i)
                    0: av = {ROWS{8'h80}};
                    1: av = {ROWS{8'h7F}};
                    2: av = {ROWS{8'hFF}};
                    default: av = {ROWS{8'h00}};
                endcase
                for (k = 0; k < ROWS + COLS + 2; k = k + 1)
                    drive(1'b0, {ROWS{1'b1}}, av, 0);
            end
        end

        // ---- random ----
        for (i = 0; i < NTRIALS; i = i + 1) begin
            av = 0; wv = 0;
            for (r = 0; r < ROWS; r = r + 1) av[r*N +: N] = rnd64(0);
            for (c = 0; c < COLS; c = c + 1) wv[c*N +: N] = rnd64(0);
            drive(((rnd64(0) & 15) == 0), rnd64(0), av, wv);
        end

        // ---- reset mid-stream ----
        @(negedge clk); reset_n = 0;
        repeat (2) @(posedge clk);
        @(negedge clk); reset_n = 1;
        for (i = 0; i < 20; i = i + 1) begin
            av = 0; for (r = 0; r < ROWS; r = r + 1) av[r*N +: N] = rnd64(0);
            drive(i < ROWS, {ROWS{1'b1}}, av, {COLS{8'h05}});
        end

        $display("[ARR] cycles=%0d  nonzero psum samples=%0d  mismatches=%0d", cycles, nonzero, errors);
        if (errors == 0 && nonzero > 0) $display("PASS");
        else if (errors == 0)           $display("FAIL (all outputs zero: not exercising the datapath)");
        else                            $display("FAIL");
        $finish;
    end
endmodule
