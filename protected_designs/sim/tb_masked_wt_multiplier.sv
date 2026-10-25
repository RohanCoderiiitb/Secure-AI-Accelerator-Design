`timescale 1ns/1ps
//=====================================================================
// tb_multiplier_masked.sv -- functional verification of the
//                            weight-masked multiplier
//
// Compile:  iverilog -g2012 -o sim multiplier_masked.sv tb_multiplier_masked.sv
// Run:      vvp sim
//
// Tests
//   T1  reset: share registers and product shares are zero
//   T2  share_multiplier alone: all 256 activations x corner-case shares
//       and random shares, against a behavioural (a*ws mod 2^SW) model
//   T3  full masked multiplier: ALL 256 weights x ALL 256 activations,
//       fresh mask per weight load, fresh refresh value every cycle.
//       Checks p0+p1 == a*w (signed) and == the unprotected BW output,
//       and that the stored shares always add back to the weight
//   T4  refresh_en = 0: stored shares must hold their values
//   T5  w_load has priority over refresh_en
//   T6  mask sanity: the stored share must almost never equal the weight
//       itself (catches a design or testbench that forgot to mask)
//
// Stimulus is driven on the negedge, results are checked just before the
// next posedge, matching the project's capture discipline.
//=====================================================================
module tb_multiplier_masked;
    localparam N  = 8;
    localparam SW = 2*N;

    // ---------------- DUT ----------------
    reg           clk = 1'b0, reset_n = 1'b0;
    reg           w_load = 1'b0, refresh_en = 1'b0;
    reg  [SW-1:0] w0_in = 0, w1_in = 0, r_refresh = 0;
    reg  [N-1:0]  a = 0;
    wire [SW-1:0] p0, p1;

    masked_weight_multiplier #(.N(N), .SW(SW)) dut (
        .clk(clk), .reset_n(reset_n),
        .w_load(w_load), .w0_in(w0_in), .w1_in(w1_in),
        .refresh_en(refresh_en), .r_refresh(r_refresh),
        .a(a), .p0(p0), .p1(p1)
    );

    // standalone share multiplier (T2)
    reg  [N-1:0]  sa  = 0;
    reg  [SW-1:0] sws = 0;
    wire [SW-1:0] sp;
    share_multiplier #(.N(N), .SW(SW)) u_sm (.a(sa), .ws(sws), .p(sp));

    // unprotected reference multiplier (T3)
    reg  [N-1:0]   w_ref = 0;
    wire [2*N-1:0] bw_p;
    baugh_wooley_multiplier #(.N(N)) u_bw (.x(a), .y(w_ref), .p(bw_p));

    always #5 clk = ~clk;

    // ---------------- xorshift64* PRNG ----------------
    reg [63:0] st = 64'h9E3779B97F4A7C15;
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

    // ---------------- helpers ----------------
    integer errs = 0, checks = 0, sec_err;
    integer wi, ai, k, unmasked_hits;
    reg signed [N-1:0]  ws_s, as_s;
    reg        [SW-1:0] w_ext, m, exp_p, got_p, hold0, hold1;

    function [SW-1:0] sext_w(input [N-1:0] v);
        sext_w = {{(SW-N){v[N-1]}}, v};
    endfunction

    // make shares outside the DUT: m random, w0 = sext(w) - m, w1 = m
    task share_and_load(input [N-1:0] w);
        begin
            @(negedge clk);
            w_ext = sext_w(w);
            m     = rnd(0);
            w0_in = w_ext - m;
            w1_in = m;
            w_load = 1'b1; refresh_en = 1'b0;
            @(negedge clk);
            w_load = 1'b0;
        end
    endtask

    task fail(input [8*48-1:0] msg);
        begin
            errs = errs + 1; sec_err = sec_err + 1;
            if (errs <= 15)
                $display("  FAIL %0s  w=%0d a=%0d p0+p1=%h exp=%h  w0=%h w1=%h",
                         msg, $signed(w_ref), $signed(a), p0 + p1, exp_p,
                         dut.w0_reg, dut.w1_reg);
        end
    endtask

    task section_end(input [8*40-1:0] name, input integer n);
        begin
            $display("%0s : %0d checks, %0d errors", name, n, sec_err);
            sec_err = 0;
        end
    endtask

    // corner-case share values for T2
    reg [SW-1:0] corner [0:7];
    integer n_sec;

    initial begin
        sec_err = 0;
        corner[0] = 16'h0000; corner[1] = 16'h0001; corner[2] = 16'h7FFF;
        corner[3] = 16'h8000; corner[4] = 16'hFFFF; corner[5] = 16'hAAAA;
        corner[6] = 16'h5555; corner[7] = 16'h0080;

        // ---------------- T1 reset ----------------
        a = 8'h7F;
        repeat (3) @(posedge clk);
        #1;
        n_sec = 1; checks = checks + 1;
        exp_p = 0;
        if (dut.w0_reg !== 0 || dut.w1_reg !== 0 || p0 !== 0 || p1 !== 0)
            fail("T1 reset");
        section_end("T1 reset              ", n_sec);
        @(negedge clk); reset_n = 1'b1;

        // ---------------- T2 share_multiplier ----------------
        n_sec = 0;
        for (ai = 0; ai < 256; ai = ai + 1) begin
            for (k = 0; k < 8 + 64; k = k + 1) begin
                sa  = ai[N-1:0];
                sws = (k < 8) ? corner[k] : rnd(0);
                #1;
                as_s  = sa;
                exp_p = sext_w(as_s) * sws;          // mod 2^SW
                checks = checks + 1; n_sec = n_sec + 1;
                if (sp !== exp_p) begin
                    errs = errs + 1; sec_err = sec_err + 1;
                    if (errs <= 15)
                        $display("  FAIL T2 a=%0d ws=%h got=%h exp=%h", as_s, sws, sp, exp_p);
                end
            end
        end
        section_end("T2 share_multiplier   ", n_sec);

        // ---------------- T3 all weights x all activations ----------------
        n_sec = 0;
        for (wi = 0; wi < 256; wi = wi + 1) begin
            w_ref = wi[N-1:0];
            share_and_load(w_ref);
            refresh_en = 1'b1;
            for (ai = 0; ai < 256; ai = ai + 1) begin
                a         = ai[N-1:0];
                r_refresh = rnd(0);
                #1;
                ws_s  = w_ref; as_s = a;
                exp_p = as_s * ws_s;                 // signed product, 16 bits
                got_p = p0 + p1;                     // recombine in the TB only
                checks = checks + 1; n_sec = n_sec + 1;
                if (got_p !== exp_p)                           fail("T3 product");
                if (got_p !== sext_w(0) + {{(SW-2*N){bw_p[2*N-1]}}, bw_p})
                                                               fail("T3 vs BW  ");
                if (dut.w0_reg + dut.w1_reg !== sext_w(w_ref))  fail("T3 shares ");
                @(negedge clk);
            end
            refresh_en = 1'b0;
        end
        section_end("T3 masked, all w x a  ", n_sec);

        // ---------------- T4 hold when refresh_en = 0 ----------------
        n_sec = 0;
        w_ref = 8'hA5;
        share_and_load(w_ref);
        hold0 = dut.w0_reg; hold1 = dut.w1_reg;
        refresh_en = 1'b0;
        for (k = 0; k < 20; k = k + 1) begin
            r_refresh = rnd(0);
            a = rnd(0);
            @(negedge clk);
            checks = checks + 1; n_sec = n_sec + 1;
            exp_p = $signed(a) * $signed(w_ref);
            if (dut.w0_reg !== hold0 || dut.w1_reg !== hold1) fail("T4 hold   ");
            if (p0 + p1 !== exp_p)                             fail("T4 product");
        end
        section_end("T4 hold, no refresh   ", n_sec);

        // ---------------- T5 load priority ----------------
        n_sec = 0;
        for (k = 0; k < 50; k = k + 1) begin
            @(negedge clk);
            w_ref = rnd(0);
            w_ext = sext_w(w_ref);
            m = rnd(0);
            w0_in = w_ext - m; w1_in = m;
            r_refresh = rnd(0);
            w_load = 1'b1; refresh_en = 1'b1;          // both asserted
            @(negedge clk);
            w_load = 1'b0; refresh_en = 1'b0;
            checks = checks + 1; n_sec = n_sec + 1;
            exp_p = 0;
            if (dut.w0_reg !== w0_in || dut.w1_reg !== w1_in) fail("T5 priority");
        end
        section_end("T5 load priority      ", n_sec);

        // ---------------- T6 mask sanity ----------------
        n_sec = 0; unmasked_hits = 0;
        w_ref = 8'h3C;
        share_and_load(w_ref);
        refresh_en = 1'b1;
        for (k = 0; k < 4096; k = k + 1) begin
            r_refresh = rnd(0);
            @(negedge clk);
            n_sec = n_sec + 1;
            if (dut.w0_reg === sext_w(w_ref) || dut.w1_reg === sext_w(w_ref))
                unmasked_hits = unmasked_hits + 1;
        end
        refresh_en = 1'b0;
        checks = checks + 1;
        // with 16-bit uniform shares, expected hits ~ 2*4096/65536 = 0.125
        if (unmasked_hits > 4) begin
            errs = errs + 1; sec_err = sec_err + 1;
            $display("  FAIL T6: share equal to the weight %0d times", unmasked_hits);
        end
        section_end("T6 mask sanity        ", n_sec);

        // ---------------- summary ----------------
        $display("------------------------------------------------");
        $display("TOTAL: %0d checks, %0d errors -> %0s",
                 checks, errs, (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule