`timescale 1ns/1ps
// ============================================================================
// tb_processing_element
//   T1 : exhaustive PE datapath check  (all 256 weights x 256 activations)
//   T2 : weight-hold + wt_out shift-chain tap behaviour
//   T3 : reset behaviour
//   T4 : mac_unit -- clr/load, multi-cycle accumulation, en gating
// Run: iverilog -g2012 -o tb_pe multiplier.v processing_element.v tb_processing_element.v
//      vvp tb_pe
// ============================================================================
module tb_processing_element;

    parameter N    = 8;
    parameter ACCW = 32;

    reg                    clk = 1'b0;
    reg                    reset_n;
    reg                    wt_load;
    reg  signed [N-1:0]    wt_in;
    reg                    valid_in;
    reg  signed [N-1:0]    act_in;
    reg  signed [ACCW-1:0] psum_in;

    wire signed [N-1:0]    wt_out;
    wire                   valid_out;
    wire signed [N-1:0]    act_out;
    wire signed [ACCW-1:0] psum_out;

    integer errors = 0;
    integer checks = 0;

    always #5 clk = ~clk;

    processing_element #(.N(N), .ACCW(ACCW)) dut (
        .clk(clk), .reset_n(reset_n),
        .wt_load(wt_load), .wt_in(wt_in), .wt_out(wt_out),
        .valid_in(valid_in), .act_in(act_in), .psum_in(psum_in),
        .valid_out(valid_out), .act_out(act_out), .psum_out(psum_out)
    );

    // ---------------- helpers ------------------------------------------------
    task expect_eq;
        input signed [ACCW-1:0] got;
        input signed [ACCW-1:0] exp;
        input [255:0]           tag;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                if (errors < 20)
                    $display("  FAIL %0s @%0t : got %0d, expected %0d",
                             tag, $time, got, exp);
            end
        end
    endtask

    task load_weight;
        input signed [N-1:0] w;
        begin
            @(negedge clk);
            wt_load = 1'b1;  wt_in = w;
            valid_in = 1'b0; act_in = 0; psum_in = 0;
            @(negedge clk);
            wt_load = 1'b0;
        end
    endtask

    // ---------------- stimulus ----------------------------------------------
    integer wi, ai, k;
    reg signed [N-1:0]    w_cur, a_cur;
    reg signed [ACCW-1:0] p_cur, exp;

    initial begin
        reset_n = 1'b0; wt_load = 1'b0; wt_in = 0;
        valid_in = 1'b0; act_in = 0; psum_in = 0;
        repeat (3) @(negedge clk);

        // ---------------- T3 (reset) ----------------------------------------
        @(posedge clk); #1;
        expect_eq(psum_out,  0, "T3.psum_reset");
        expect_eq(act_out,   0, "T3.act_reset");
        expect_eq(valid_out, 0, "T3.valid_reset");
        expect_eq(wt_out,    0, "T3.wt_reset");
        reset_n = 1'b1;

        // ---------------- T1 : exhaustive datapath ---------------------------
        $display("T1: exhaustive PE sweep (256 weights x 256 activations)...");
        for (wi = 0; wi < 256; wi = wi + 1) begin
            w_cur = wi[N-1:0];
            load_weight(w_cur);

            // T2 : wt_out must mirror the held weight (shift-chain tap)
            expect_eq($signed(wt_out), $signed(w_cur), "T2.wt_out");

            for (ai = 0; ai < 256; ai = ai + 1) begin
                a_cur = ai[N-1:0];
                // vary psum_in so accumulation, not just the product, is checked
                p_cur = $signed({wi[3:0], ai[7:0], 4'b0}) - 32'sd8192;

                @(negedge clk);
                act_in   = a_cur;
                psum_in  = p_cur;
                valid_in = ai[0];

                exp = p_cur + (a_cur * w_cur);

                @(posedge clk); #1;
                expect_eq(psum_out,        exp,          "T1.psum");
                expect_eq($signed(act_out), $signed(a_cur), "T1.act_fwd");
                expect_eq(valid_out,       ai[0],        "T1.valid_fwd");
            end
        end
        $display("T1/T2 done: %0d checks, %0d errors", checks, errors);

        // ---------------- weight must be HELD when wt_load = 0 ---------------
        @(negedge clk);
        wt_in = 8'sh7F;  wt_load = 1'b0;   // must be ignored
        @(posedge clk); #1;
        expect_eq($signed(wt_out), $signed(w_cur), "T2.wt_hold");

        // ---------------- T4 : mac_unit -------------------------------------
        run_mac_test;

        $display("--------------------------------------------------");
        if (errors == 0) $display("tb_processing_element: PASS  (%0d checks)", checks);
        else             $display("tb_processing_element: FAIL  (%0d/%0d errors)", errors, checks);
        $display("--------------------------------------------------");
        $finish;
    end

    // ======================= mac_unit sub-test ==============================
    reg                    m_reset_n, m_en, m_clr;
    reg  signed [N-1:0]    m_act, m_wt;
    wire signed [ACCW-1:0] m_accum;

    mac_unit #(.N(N), .ACCW(ACCW)) u_mac (
        .clk(clk), .reset_n(m_reset_n), .en(m_en), .clr(m_clr),
        .act(m_act), .wt(m_wt), .accum(m_accum)
    );

    integer t, vlen;
    reg signed [ACCW-1:0] m_ref;
    reg signed [N-1:0]    va [0:63];
    reg signed [N-1:0]    vw [0:63];

    task run_mac_test;
        integer trial;
        begin
            $display("T4: mac_unit accumulation...");
            m_reset_n = 1'b0; m_en = 1'b0; m_clr = 1'b0; m_act = 0; m_wt = 0;
            repeat (2) @(negedge clk);
            @(posedge clk); #1;
            expect_eq(m_accum, 0, "T4.reset");
            m_reset_n = 1'b1;

            for (trial = 0; trial < 8; trial = trial + 1) begin
                vlen = 16 + (trial * 5);
                if (vlen > 64) vlen = 64;
                for (t = 0; t < vlen; t = t + 1) begin
                    va[t] = $random;
                    vw[t] = $random;
                end
                // force the saturating corners into the first trial
                if (trial == 0) begin
                    va[0] = -8'sd128; vw[0] = -8'sd128;
                    va[1] = -8'sd128; vw[1] =  8'sd127;
                    va[2] =  8'sd127; vw[2] =  8'sd127;
                end

                m_ref = 0;
                for (t = 0; t < vlen; t = t + 1) begin
                    @(negedge clk);
                    m_act = va[t];
                    m_wt  = vw[t];
                    m_en  = 1'b1;
                    m_clr = (t == 0);          // first term loads, rest accumulate
                    m_ref = (t == 0) ? (va[t]*vw[t]) : (m_ref + va[t]*vw[t]);
                    @(posedge clk); #1;
                    expect_eq(m_accum, m_ref, "T4.accum");
                end

                // en = 0 must freeze the accumulator
                @(negedge clk);
                m_en = 1'b0; m_clr = 1'b0; m_act = 8'sd77; m_wt = 8'sd55;
                repeat (3) begin
                    @(posedge clk); #1;
                    expect_eq(m_accum, m_ref, "T4.en_gate");
                end

                // clr with en = 0 must zero the accumulator
                @(negedge clk);
                m_clr = 1'b1; m_en = 1'b0;
                @(posedge clk); #1;
                expect_eq(m_accum, 0, "T4.clr_zero");
                @(negedge clk);
                m_clr = 1'b0;
                m_ref = 0;
            end
        end
    endtask

endmodule
