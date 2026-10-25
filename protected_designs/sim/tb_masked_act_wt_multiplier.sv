`timescale 1ns/1ps
//=====================================================================
// tb_masked_multiplier_aw.sv -- functional verification of
//                               masked_multiplier_aw (activation and
//                               weight both masked)
//
// Compile:
//   iverilog -g2012 -o sim ../source/masked_multiplier.sv \
//            ../source/masked_multiplier_aw.sv tb_masked_multiplier_aw.sv
//   vvp sim
//
// Tests
//   T1  reset: everything zero
//   T2  share_multiplier with N = SW (16 x 16, low 16 bits) against a
//       behavioural model: corner cases and random operands
//   T3  ALL 256 weights x ALL 256 activations, fresh activation shares,
//       fresh cross-term random and fresh weight refresh every cycle.
//       Checks p0 + p1 == a*w one cycle later (latency 1), and that the
//       weight shares always add back to the weight
//   T4  mask sanity: p0 alone must almost never equal the product
//   T5  masks off (all random values 0): p0 == a*w and p1 == 0 exactly.
//       This is the configuration the TVLA sanity control uses
//
// Stimulus on the negedge; outputs checked on the following negedge,
// i.e. one posedge (the pipeline register) after the inputs were applied.
//=====================================================================
module tb_masked_multiplier_aw;
    localparam N  = 8;
    localparam SW = 2*N;

    reg           clk = 1'b0, reset_n = 1'b0;
    reg           w_load = 1'b0, refresh_en = 1'b0;
    reg  [SW-1:0] w0_in = 0, w1_in = 0, r_refresh = 0;
    reg  [SW-1:0] a0 = 0, a1 = 0, r_cross = 0;
    wire [SW-1:0] p0, p1;

    masked_multiplier_aw #(.N(N), .SW(SW)) dut (
        .clk(clk), .reset_n(reset_n),
        .w_load(w_load), .w0_in(w0_in), .w1_in(w1_in),
        .refresh_en(refresh_en), .r_refresh(r_refresh),
        .a0(a0), .a1(a1), .r_cross(r_cross),
        .p0(p0), .p1(p1)
    );

    // standalone 16 x 16 share multiplier (T2)
    reg  [SW-1:0] sx = 0, sy = 0;
    wire [SW-1:0] sp;
    share_multiplier #(.N(SW), .SW(SW)) u_sm (.a(sx), .ws(sy), .p(sp));

    always #5 clk = ~clk;

    // ---------------- xorshift64* ----------------
    reg [63:0] st = 64'h9E3779B97F4A7C15;
    reg        masks_off = 1'b0;
    function [SW-1:0] rnd;
        input dummy;
        reg [63:0] t;
        begin
            t  = st ^ (st >> 12);
            t  = t  ^ (t  << 25);
            t  = t  ^ (t  >> 27);
            st = t;
            rnd = (t * 64'h2545F4914F6CDD1D) >> 20;
        end
    endfunction
    // random value used as a mask; zero when masks are switched off
    function [SW-1:0] mrnd;
        input dummy;
        reg [SW-1:0] v;
        begin
            v    = rnd(0);
            mrnd = masks_off ? {SW{1'b0}} : v;
        end
    endfunction

    function [SW-1:0] sext(input [N-1:0] v);
        sext = {{(SW-N){v[N-1]}}, v};
    endfunction

    integer errs = 0, checks = 0, sec_err = 0, n_sec;
    integer wi, ai, k, hits;
    reg [N-1:0]  w_cur, a_cur, a_prev;
    reg [SW-1:0] m, exp_p, w_ext;
    reg          have_prev;

    task share_and_load_weight(input [N-1:0] w);
        begin
            @(negedge clk);
            w_ext = sext(w);
            m = mrnd(0);
            w0_in = w_ext - m; w1_in = m;
            w_load = 1'b1; refresh_en = 1'b0;
            @(negedge clk);
            w_load = 1'b0; refresh_en = 1'b1;
        end
    endtask

    // drive fresh activation shares and fresh randoms for one cycle
    task drive_act(input [N-1:0] a);
        begin
            m         = mrnd(0);
            a0        = sext(a) - m;
            a1        = m;
            r_cross   = mrnd(0);
            r_refresh = mrnd(0);
        end
    endtask

    task bad(input [8*40-1:0] msg);
        begin
            errs = errs + 1; sec_err = sec_err + 1;
            if (errs <= 15)
                $display("  FAIL %0s  w=%0d a=%0d p0=%h p1=%h p0+p1=%h exp=%h",
                         msg, $signed(w_cur), $signed(a_prev), p0, p1, p0 + p1, exp_p);
        end
    endtask

    task section_end(input [8*40-1:0] name, input integer n);
        begin
            $display("%0s : %0d checks, %0d errors", name, n, sec_err);
            sec_err = 0;
        end
    endtask

    reg [SW-1:0] corner [0:7];

    initial begin
        corner[0] = 16'h0000; corner[1] = 16'h0001; corner[2] = 16'h7FFF;
        corner[3] = 16'h8000; corner[4] = 16'hFFFF; corner[5] = 16'hAAAA;
        corner[6] = 16'h5555; corner[7] = 16'h00FF;

        // ---------------- T1 reset ----------------
        a0 = 16'h1234; a1 = 16'h4321;
        repeat (3) @(posedge clk); #1;
        checks = checks + 1;
        if (p0 !== 0 || p1 !== 0 || dut.w0_reg !== 0 || dut.w1_reg !== 0) bad("T1 reset");
        section_end("T1 reset                 ", 1);
        @(negedge clk); reset_n = 1'b1;

        // ---------------- T2 16x16 share multiplier ----------------
        n_sec = 0;
        for (k = 0; k < 64 + 20000; k = k + 1) begin
            sx = (k < 64) ? corner[k % 8] : rnd(0);
            sy = (k < 64) ? corner[k / 8] : rnd(0);
            #1;
            exp_p = sx * sy;                         // mod 2^SW
            checks = checks + 1; n_sec = n_sec + 1;
            if (sp !== exp_p) begin
                errs = errs + 1; sec_err = sec_err + 1;
                if (errs <= 15) $display("  FAIL T2 x=%h y=%h got=%h exp=%h", sx, sy, sp, exp_p);
            end
        end
        section_end("T2 share mult 16x16      ", n_sec);

        // ---------------- T3 all weights x all activations ----------------
        n_sec = 0;
        for (wi = 0; wi < 256; wi = wi + 1) begin
            w_cur = wi[N-1:0];
            share_and_load_weight(w_cur);
            have_prev = 1'b0;
            for (ai = 0; ai <= 256; ai = ai + 1) begin
                // check the pair applied on the previous negedge
                if (have_prev) begin
                    exp_p = $signed(a_prev) * $signed(w_cur);
                    checks = checks + 1; n_sec = n_sec + 1;
                    if (p0 + p1 !== exp_p)                    bad("T3 product");
                    if (dut.w0_reg + dut.w1_reg !== sext(w_cur)) bad("T3 w shares");
                end
                if (ai < 256) begin
                    a_cur = ai[N-1:0];
                    drive_act(a_cur);
                    a_prev = a_cur; have_prev = 1'b1;
                    @(negedge clk);
                end
            end
            refresh_en = 1'b0;
        end
        section_end("T3 all w x a (65536)     ", n_sec);

        // ---------------- T4 mask sanity ----------------
        n_sec = 0; hits = 0;
        w_cur = 8'hB3;
        share_and_load_weight(w_cur);
        have_prev = 1'b0;
        for (k = 0; k <= 4096; k = k + 1) begin
            if (have_prev) begin
                exp_p = $signed(a_prev) * $signed(w_cur);
                n_sec = n_sec + 1;
                if (p0 === exp_p || p1 === exp_p) hits = hits + 1;
            end
            a_cur = rnd(0);
            drive_act(a_cur);
            a_prev = a_cur; have_prev = 1'b1;
            @(negedge clk);
        end
        refresh_en = 1'b0;
        checks = checks + 1;
        if (hits > 4) begin
            errs = errs + 1; sec_err = sec_err + 1;
            $display("  FAIL T4: a single share equalled the product %0d times", hits);
        end
        section_end("T4 mask sanity           ", n_sec);

        // ---------------- T5 masks off ----------------
        n_sec = 0;
        masks_off = 1'b1;
        for (k = 0; k < 64; k = k + 1) begin
            w_cur = rnd(0);
            share_and_load_weight(w_cur);
            a_cur = rnd(0);
            drive_act(a_cur);
            a_prev = a_cur;
            @(negedge clk);
            exp_p = $signed(a_prev) * $signed(w_cur);
            checks = checks + 1; n_sec = n_sec + 1;
            if (p0 !== exp_p || p1 !== 0) bad("T5 masks off");
            refresh_en = 1'b0;
        end
        masks_off = 1'b0;
        section_end("T5 masks off             ", n_sec);

        $display("------------------------------------------------");
        $display("TOTAL: %0d checks, %0d errors -> %0s",
                 checks, errs, (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
