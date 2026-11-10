`timescale 1ns/1ps
// Masked requantizer vs plain requantize: correctness, latency and throughput
module tb_requant_latency;
    localparam N = 8, ACCW = 19, MW = 16, SW = 6, XW = 19, BW = 32;
    localparam BMW = BW + MW;
    localparam RW = XW + MW + 2;
    localparam TEAMMATE_CYCLES = 29;            // as reported for the earlier masked design

    `include "msk_counts.vh"
    localparam RND_W = mskf_rq_rnd(XW, RW);

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg                    reset_n, valid_in;
    reg  signed [ACCW-1:0] acc;
    reg  signed [BW-1:0]   bias;
    reg  signed [BMW-1:0]  bm;
    reg  signed [MW-1:0]   m0;
    reg  [31:0]            m32;
    reg  [SW-1:0]          sh;
    reg  [XW-1:0]          x0, x1;

    wire vr, sr; wire [N-1:0] qr;
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW), .BMW(BMW)) u_ref (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .acc_in(acc), .bm_in(bm),
        .m0_in(m0), .shift_in(sh), .valid_out(vr), .q_out(qr), .sat_out(sr));

    wire [RND_W-1:0] rnd1, rnd0;
    rng_bank #(.W(RND_W), .SEED(64'h1111)) u_rng1 (.clk(clk), .reset_n(reset_n), .en(1'b1), .rnd(rnd1));
    rng_bank #(.W(RND_W), .SEED(64'h2222)) u_rng0 (.clk(clk), .reset_n(reset_n), .en(1'b1), .rnd(rnd0));

    wire v1, s10, s11, v0, s00, s01; wire [N-1:0] q10, q11, q00, q01;
    requantize_masked #(.N(N), .XW(XW), .MW(MW), .SW(SW), .BMW(BMW), .DOM_REG(1)) u_m1 (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .col_in(1'b0), .x0_in(x0), .x1_in(x1),
        .bm_tab(bm), .m0_tab(m0), .shift_tab(sh), .rnd_in(rnd1),
        .valid_out(v1), .col_out(), .q0_out(q10), .q1_out(q11), .sat0_out(s10), .sat1_out(s11));
    requantize_masked #(.N(N), .XW(XW), .MW(MW), .SW(SW), .BMW(BMW), .DOM_REG(0)) u_m0 (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in), .col_in(1'b0), .x0_in(x0), .x1_in(x1),
        .bm_tab(bm), .m0_tab(m0), .shift_tab(sh), .rnd_in(rnd0),
        .valid_out(v0), .col_out(), .q0_out(q00), .q1_out(q01), .sat0_out(s00), .sat1_out(s01));

    // behavioural model
    function [N:0] model;
        input signed [ACCW-1:0] a;
        reg signed [63:0] v, r;
        begin
            v = (a + bias) * m0;
            r = (sh == 0) ? 64'sd0 : (64'sd1 <<< (sh - 1));
            v = (v + r) >>> sh;
            if (v > 127)       model = {1'b1, 8'h7F};
            else if (v < -128) model = {1'b1, 8'h80};
            else               model = {1'b0, v[7:0]};
        end
    endfunction
    reg [N:0] golden [0:255];

    integer NBURST, NB, SEED, seed;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // per-burst bookkeeping
    integer t_in, f_r, f_1, f_0, l_r, l_1, l_0, n_r, n_1, n_0;
    reg [N:0] exp_q [0:255];
    reg [N:0] got1  [0:255];
    reg [N:0] got0  [0:255];
    always @(negedge clk) if (reset_n) begin
        if (vr) begin if (n_r == 0) f_r = cyc; l_r = cyc; exp_q[n_r] = {sr, qr};          n_r = n_r + 1; end
        if (v1) begin if (n_1 == 0) f_1 = cyc; l_1 = cyc; got1[n_1]  = {s10^s11, q10^q11}; n_1 = n_1 + 1; end
        if (v0) begin if (n_0 == 0) f_0 = cyc; l_0 = cyc; got0[n_0]  = {s00^s01, q00^q01}; n_0 = n_0 + 1; end
    end

    integer b, k, errors = 0, gerrors = 0, sat_cnt = 0, total = 0;
    integer lat_r, lat_1, lat_0, bur_r, bur_1, bur_0;
    reg [XW-1:0] accx;

    task run_burst;
        input integer nb;
        begin
            n_r = 0; n_1 = 0; n_0 = 0;
            bias = ($random(seed) % 32768);
            m32  = {1'b0, 1'b1, 30'h0} | ($random(seed) & 32'h3FFF_FFFF);   // Q0.31, >= 0.5
            m0   = m32[31:16];                                              // top 16 bits
            bm   = bias * m0;                                               // per-layer constant
            sh   = (($random(seed) & 7) == 0) ? ($unsigned($random(seed)) % 14)
                                              : 14 + ($unsigned($random(seed)) % 14);  // 14..27
            repeat (2) @(negedge clk);                                      // constants settle
            for (k = 0; k < nb; k = k + 1) begin
                @(negedge clk);
                if (k == 0) t_in = cyc;
                acc  = ($random(seed) % 65536);
                golden[k] = model(acc);
                accx = acc[XW-1:0];
                x0   = $random(seed);
                x1   = accx - x0;
                valid_in = 1'b1;
            end
            @(negedge clk); valid_in = 1'b0; acc = 0; x0 = $random(seed); x1 = $random(seed);
            repeat (mskf_rq_lat(XW, RW, 1) + 6) @(negedge clk);
            if (n_r != nb || n_1 != nb || n_0 != nb) begin
                errors = errors + 1;
                $display("[FAIL] burst %0d: counts ref=%0d m1=%0d m0=%0d (exp %0d)", b, n_r, n_1, n_0, nb);
            end
            for (k = 0; k < nb; k = k + 1) begin
                total = total + 1;
                if (exp_q[k][N]) sat_cnt = sat_cnt + 1;
                if (exp_q[k] !== golden[k]) begin
                    gerrors = gerrors + 1;
                    if (gerrors <= 10)
                        $display("[FAIL] burst %0d item %0d sh=%0d: requantize=%h model=%h",
                                 b, k, sh, exp_q[k], golden[k]);
                end
                if (got1[k] !== exp_q[k] || got0[k] !== exp_q[k]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("[FAIL] burst %0d item %0d sh=%0d: ref=%h m1=%h m0=%h",
                                 b, k, sh, exp_q[k], got1[k], got0[k]);
                end
            end
            if (nb == 1) begin lat_r = f_r - t_in; lat_1 = f_1 - t_in; lat_0 = f_0 - t_in; end
            else begin bur_r = l_r - t_in + 1; bur_1 = l_1 - t_in + 1; bur_0 = l_0 - t_in + 1; end
        end
    endtask

    initial begin
        if (!$value$plusargs("NBURST=%d", NBURST)) NBURST = 300;
        if (!$value$plusargs("NB=%d",     NB))     NB     = 16;
        if (!$value$plusargs("SEED=%d",   SEED))   SEED   = 1;
        seed = SEED;
        reset_n = 0; valid_in = 0; acc = 0; bias = 0; m0 = 0; sh = 0; x0 = 0; x1 = 0;
        repeat (5) @(posedge clk);
        @(negedge clk) reset_n = 1;
        repeat (mskf_rq_lat(XW, RW, 1) + 4) @(negedge clk);

        for (b = 0; b < NBURST; b = b + 1) run_burst((b == 0) ? 1 : NB);
        run_burst(1);
        $display("");
        $display("================ requantizer latency / throughput ================");
        $display("  random bits per cycle (masked) : %0d", RND_W);
        $display("  %-40s %8s %22s", "design", "latency", "cycles for a burst");
        $display("  %-40s %8d %22d", "requantize (unprotected)",               lat_r, bur_r);
        $display("  %-40s %8s %22s", "teammate's masked requant (reported)",   "29", "29 per value");
        $display("  %-40s %8s %22s", "our v1 masked requant (reported)",       "22", "38");
        $display("  %-40s %8d %22d", "requantize_masked v3 DOM_REG=1 (robust)", lat_1, bur_1);
        $display("  %-40s %8d %22d", "requantize_masked v3 DOM_REG=0 (RTL)",   lat_0, bur_0);
        $display("  MW=%0d XW=%0d RW=%0d, bias*m0 precomputed", MW, XW, RW);
        $display("  burst = %0d back-to-back values; masked designs accept 1 new value per cycle", NB);
        $display("  teammate's design if 1 value per 29 cycles: %0d cycles for the same burst", NB * TEAMMATE_CYCLES);
        $display("  checked %0d values (%0d saturated, %0d in range)", total, sat_cnt, total - sat_cnt);
        if (gerrors == 0) $display("  [REQUANT] PASS: requantize identical to the behavioural model");
        else              $display("  [REQUANT] FAIL: requantize vs model: %0d mismatches", gerrors);
        if (errors == 0) $display("  [REQUANT] PASS: masked outputs identical to requantize");
        else             $display("  [REQUANT] FAIL: %0d mismatches", errors);
        $display("==================================================================");
        $finish;
    end
endmodule
