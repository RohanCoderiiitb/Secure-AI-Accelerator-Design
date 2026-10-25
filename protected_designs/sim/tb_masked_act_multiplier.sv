`timescale 1ns/1ps
//=====================================================================
// tb_masked_act_multiplier.sv -- functional verification of
//                                masked_act_multiplier (activation masked,
//                                weight plain)
//
// Compile:
//   iverilog -g2012 -o sim_act ../source/masked_multiplier.sv \
//            ../source/masked_act_multiplier.sv tb_masked_act_multiplier.sv
//   vvp sim_act
//
// Tests
//   T1  reset: weight register zero
//   T2  ALL 256 weights x ALL 256 activations, fresh activation shares
//       every cycle: p0 + p1 == a*w, and == the original Baugh-Wooley output
//   T3  same pair, many different masks: sum always correct, shares change
//   T4  weight hold: w_load = 0 keeps the weight
//   T5  mask sanity: a single share almost never equals the product
//   T6  masks off (m = 0): p0 == a*w and p1 == 0 exactly (TVLA control mode)
//=====================================================================
module tb_masked_act_multiplier;
    localparam N  = 8;
    localparam SW = 2*N;

    reg           clk = 1'b0, reset_n = 1'b0, w_load = 1'b0;
    reg  [N-1:0]  w_in = 0;
    reg  [SW-1:0] a0 = 0, a1 = 0;
    wire [SW-1:0] p0, p1;

    masked_act_multiplier #(.N(N), .SW(SW)) dut (
        .clk(clk), .reset_n(reset_n), .w_load(w_load), .w_in(w_in),
        .a0(a0), .a1(a1), .p0(p0), .p1(p1)
    );

    // reference: the original unmasked Baugh-Wooley multiplier
    reg  [N-1:0]   ref_a = 0;
    wire [2*N-1:0] ref_p;
    baugh_wooley_multiplier #(.N(N)) u_ref (.x(ref_a), .y(dut.w_reg), .p(ref_p));

    always #5 clk = ~clk;

    // ---------------- xorshift64* ----------------
    reg [63:0] st = 64'h2545F4914F6CDD1D;
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

    function [SW-1:0] sext(input [N-1:0] v);
        sext = {{(SW-N){v[N-1]}}, v};
    endfunction

    integer errs = 0, checks = 0, sec_err = 0, n_sec;
    integer wi, ai, k, hits, changes;
    reg [N-1:0]  w_cur, a_cur;
    reg [SW-1:0] m, exp_p, p0_prev;

    task load_weight(input [N-1:0] w);
        begin
            @(negedge clk); w_in = w; w_load = 1'b1;
            @(negedge clk); w_load = 1'b0;
        end
    endtask

    // fresh shares of activation a
    task share_act(input [N-1:0] a);
        begin
            m  = masks_off ? {SW{1'b0}} : rnd(0);
            a0 = sext(a) - m;
            a1 = m;
            ref_a = a;
            #1;
        end
    endtask

    task bad(input [8*40-1:0] msg);
        begin
            errs = errs + 1; sec_err = sec_err + 1;
            if (errs <= 15)
                $display("  FAIL %0s  w=%0d a=%0d p0=%h p1=%h p0+p1=%h exp=%h",
                         msg, $signed(w_cur), $signed(a_cur), p0, p1, p0 + p1, exp_p);
        end
    endtask

    task section_end(input [8*40-1:0] name, input integer n);
        begin
            $display("%0s : %0d checks, %0d errors", name, n, sec_err);
            sec_err = 0;
        end
    endtask

    initial begin
        // ---------------- T1 reset ----------------
        w_in = 8'h5A; w_load = 1'b1;
        repeat (3) @(posedge clk); #1;
        checks = checks + 1;
        if (dut.w_reg !== 0) bad("T1 reset");
        section_end("T1 reset              ", 1);
        @(negedge clk); reset_n = 1'b1; w_load = 1'b0;

        // ---------------- T2 all w x a ----------------
        n_sec = 0;
        for (wi = 0; wi < 256; wi = wi + 1) begin
            w_cur = wi[N-1:0];
            load_weight(w_cur);
            for (ai = 0; ai < 256; ai = ai + 1) begin
                a_cur = ai[N-1:0];
                share_act(a_cur);
                exp_p = $signed(a_cur) * $signed(w_cur);
                checks = checks + 2; n_sec = n_sec + 2;
                if (p0 + p1 !== exp_p)  bad("T2 product");
                if (p0 + p1 !== ref_p)  bad("T2 vs Baugh-Wooley");
            end
        end
        section_end("T2 all w x a (65536)  ", n_sec);

        // ---------------- T3 same pair, many masks ----------------
        n_sec = 0; changes = 0;
        w_cur = 8'h81; load_weight(w_cur);          // -127
        a_cur = 8'h80;                              // -128
        exp_p = $signed(a_cur) * $signed(w_cur);
        p0_prev = 0;
        for (k = 0; k < 2000; k = k + 1) begin
            share_act(a_cur);
            checks = checks + 1; n_sec = n_sec + 1;
            if (p0 + p1 !== exp_p) bad("T3 product");
            if (p0 !== p0_prev) changes = changes + 1;
            p0_prev = p0;
        end
        checks = checks + 1;
        if (changes < 1990) begin
            errs = errs + 1; sec_err = sec_err + 1;
            $display("  FAIL T3: p0 changed only %0d / 2000 times", changes);
        end
        section_end("T3 one pair, 2000 masks", n_sec);

        // ---------------- T4 weight hold ----------------
        n_sec = 0;
        w_cur = 8'h37; load_weight(w_cur);
        w_in = 8'hC4;                               // w_load stays 0
        for (k = 0; k < 50; k = k + 1) begin
            @(negedge clk);
            a_cur = rnd(0);
            share_act(a_cur);
            exp_p = $signed(a_cur) * $signed(w_cur);
            checks = checks + 1; n_sec = n_sec + 1;
            if (dut.w_reg !== w_cur || p0 + p1 !== exp_p) bad("T4 hold");
        end
        section_end("T4 weight hold        ", n_sec);

        // ---------------- T5 mask sanity ----------------
        n_sec = 0; hits = 0;
        w_cur = 8'hB3; load_weight(w_cur);
        for (k = 0; k < 4096; k = k + 1) begin
            a_cur = rnd(0);
            share_act(a_cur);
            exp_p = $signed(a_cur) * $signed(w_cur);
            n_sec = n_sec + 1;
            if (exp_p != 0 && (p0 === exp_p || p1 === exp_p)) hits = hits + 1;
        end
        checks = checks + 1;
        if (hits > 4) begin
            errs = errs + 1; sec_err = sec_err + 1;
            $display("  FAIL T5: a single share equalled the product %0d times", hits);
        end
        section_end("T5 mask sanity        ", n_sec);

        // ---------------- T6 masks off ----------------
        n_sec = 0; masks_off = 1'b1;
        for (k = 0; k < 256; k = k + 1) begin
            if (k % 16 == 0) begin w_cur = rnd(0); load_weight(w_cur); end
            a_cur = rnd(0);
            share_act(a_cur);
            exp_p = $signed(a_cur) * $signed(w_cur);
            checks = checks + 1; n_sec = n_sec + 1;
            if (p0 !== exp_p || p1 !== 0) bad("T6 masks off");
        end
        masks_off = 1'b0;
        section_end("T6 masks off          ", n_sec);

        $display("------------------------------------------------");
        $display("TOTAL: %0d checks, %0d errors -> %0s",
                 checks, errs, (errs == 0) ? "PASS" : "FAIL");
        $finish;
    end
endmodule
