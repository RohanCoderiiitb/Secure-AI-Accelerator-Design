`timescale 1ns/1ps
//=====================================================================
// tb_processing_element_masked_act.sv -- processing_element_masked_act
//
// Compile (from protected_designs/sim):
//   iverilog -g2012 -o pe_act.vvp ../source/masked_wt_multiplier.sv \
//     ../source/processing_element_masked_act.sv tb_processing_element_masked_act.sv
//   vvp pe_act.vvp
//
// Every cycle checks against a behavioural model (signed weight x
// sign-extended activation share, mod 2^SHARE_W):
//   psum{0,1}_out, act{0,1}_out, wt_out, valid_out
// plus the share-recombination identity
//   (psum0_out + psum1_out) == baseline psum_out   (psum_pub + wt*act)
// Directed corners (-128, 127, 0, -1 ...), reset behaviour, then random.
//=====================================================================
module tb_processing_element_masked_act;
    localparam integer N = 8;
    localparam integer SHARE_W = 32;
    localparam integer RANDOM_TESTS = 20000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n, wt_load, valid_in;
    reg signed [N-1:0]  wt_in;
    reg [SHARE_W-1:0]   act0_in, act1_in, psum0_in, psum1_in;

    wire valid_out;
    wire signed [N-1:0] wt_out;
    wire [SHARE_W-1:0]  act0_out, act1_out, psum0_out, psum1_out;

    processing_element_masked_act #(.N(N), .SHARE_W(SHARE_W)) dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_in(wt_in),
        .valid_in(valid_in), .act0_in(act0_in), .act1_in(act1_in),
        .psum0_in(psum0_in), .psum1_in(psum1_in),
        .valid_out(valid_out), .wt_out(wt_out),
        .act0_out(act0_out), .act1_out(act1_out),
        .psum0_out(psum0_out), .psum1_out(psum1_out));

    reg signed [N-1:0] model_wt;
    reg [SHARE_W-1:0]  exp_ps0, exp_ps1, pub_act, exp_pub;
    reg signed [63:0]  w64, a64;
    reg [63:0]         pr;

    integer tests = 0, errors = 0, i;

    reg [63:0] st = 64'h2545F4914F6CDD1D;
    function [63:0] rnd64(input dummy);
        reg [63:0] t;
        begin
            t = st ^ (st >> 12); t = t ^ (t << 25); t = t ^ (t >> 27);
            st = t;
            rnd64 = t * 64'h2545F4914F6CDD1D;
        end
    endfunction

    // product of signed weight and (zero-extended) 32-bit share, mod 2^SHARE_W
    function [SHARE_W-1:0] mulmod(input signed [N-1:0] w, input [SHARE_W-1:0] s);
        reg signed [63:0] ww;
        reg [63:0] p;
        begin
            ww = w;
            p  = ww * $signed({32'b0, s});
            mulmod = p[SHARE_W-1:0];
        end
    endfunction

    // Drive on negedge, check just after posedge. The model uses the weight
    // register from BEFORE this edge (nonblocking semantics).
    task step(input r_n, input ld, input signed [N-1:0] w, input v,
              input [SHARE_W-1:0] a0, input [SHARE_W-1:0] a1,
              input [SHARE_W-1:0] p0, input [SHARE_W-1:0] p1);
        begin
            @(negedge clk);
            reset_n = r_n; wt_load = ld; wt_in = w; valid_in = v;
            act0_in = a0; act1_in = a1; psum0_in = p0; psum1_in = p1;

            exp_ps0 = p0 + mulmod(model_wt, a0);
            exp_ps1 = p1 + mulmod(model_wt, a1);
            // public view: psum_pub + wt * (a0 + a1)
            pub_act = a0 + a1;
            exp_pub = (p0 + p1) + mulmod(model_wt, pub_act);

            @(posedge clk); #1;
            tests = tests + 1;

            if (!r_n) begin
                model_wt = 0;
                if (valid_out !== 1'b0 || wt_out !== 0 || act0_out !== 0 ||
                    act1_out !== 0 || psum0_out !== 0 || psum1_out !== 0) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: reset outputs incorrect", tests);
                end
            end else begin
                if (psum0_out !== exp_ps0) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: psum0 got=%h exp=%h", tests, psum0_out, exp_ps0);
                end
                if (psum1_out !== exp_ps1) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: psum1 got=%h exp=%h", tests, psum1_out, exp_ps1);
                end
                if ((psum0_out + psum1_out) !== exp_pub) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: recombined psum got=%h exp=%h",
                             tests, psum0_out + psum1_out, exp_pub);
                end
                if (act0_out !== a0 || act1_out !== a1) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: act share forward", tests);
                end
                if (valid_out !== v) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: valid_out got=%b exp=%b", tests, valid_out, v);
                end
                if (ld) model_wt = w;
                if (wt_out !== model_wt) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: wt_out got=%0d exp=%0d", tests, wt_out, model_wt);
                end
            end
        end
    endtask

    // fresh sharing of signed activation a with random mask
    reg [SHARE_W-1:0] m, ae;
    task act_step(input r_n, input ld, input signed [N-1:0] w, input v,
                  input signed [N-1:0] a, input [SHARE_W-1:0] p0, input [SHARE_W-1:0] p1);
        begin
            m  = rnd64(0);
            ae = {{(SHARE_W-N){a[N-1]}}, a};
            step(r_n, ld, w, v, m, ae - m, p0, p1);
        end
    endtask

    integer wi, ai;
    reg signed [N-1:0] cw [0:4];
    reg signed [N-1:0] ca [0:4];

    initial begin
        reset_n = 0; wt_load = 0; wt_in = 0; valid_in = 0;
        act0_in = 0; act1_in = 0; psum0_in = 0; psum1_in = 0; model_wt = 0;
        cw[0] = -128; cw[1] = 127; cw[2] = 0; cw[3] = -1; cw[4] = 1;
        ca[0] = -128; ca[1] = 127; ca[2] = 0; ca[3] = -1; ca[4] = 1;

        step(0, 0, 0, 0, 0, 0, 0, 0);

        // directed: every (weight, activation) corner, shared with random masks
        for (wi = 0; wi < 5; wi = wi + 1) begin
            act_step(1, 1, cw[wi], 0, 0, 0, 0);
            for (ai = 0; ai < 5; ai = ai + 1) begin
                act_step(1, 0, 0, 1, ca[ai], rnd64(0), rnd64(0));
                act_step(1, 0, 0, 1, ca[ai], 32'hFFFF_FFF0, 32'h7FFF_FFF0);
            end
        end

        // raw (not sign-extended) shares: the PE is just modular arithmetic
        step(1, 1, 8'sd77, 1, 32'hFFFF_FFFF, 32'h8000_0000, 32'h1, 32'h2);
        step(1, 0, 0, 1, 32'h8000_0000, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 32'hFFFF_FFFF);

        // random
        for (i = 0; i < RANDOM_TESTS; i = i + 1)
            act_step(1, ((rnd64(0) & 7) == 0), rnd64(0), (rnd64(0) & 3) != 0,
                     rnd64(0), rnd64(0), rnd64(0));

        // reset after activity
        step(0, 0, 0, 1, 32'h1234_5678, 32'h8765_4321, 32'hDEAD_BEEF, 32'hCAFE_F00D);
        // resume after reset: weight must have been cleared
        act_step(1, 0, 0, 1, 8'sd99, 0, 0);

        $display("");
        $display("PE tests run : %0d", tests);
        $display("Failures     : %0d", errors);
        if (errors == 0) $display("PASS: processing_element_masked_act passed all tests.");
        else             $display("FAIL: processing_element_masked_act had %0d failure(s).", errors);
        $finish;
    end
endmodule
