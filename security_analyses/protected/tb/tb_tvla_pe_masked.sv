`timescale 1ns/1ps
//=====================================================================
// tb_tvla_pe_masked.sv -- (PHASE 2) masked variant of tb_tvla_pe.v:
//                 identical stimulus, DUT = processing_element_masked.
//                 +MASK_EN=0 is the positive control (leak must return).
//                 Original header: TVLA dataset generation for a single weight-stationary
//                 processing element.
//
// The weight-load phase is deliberately OUTSIDE the capture window: a
// wt_load pulse toggles wt_reg with the secret itself and would give a
// trivially detectable, operationally irrelevant leak. What we want is
// the leakage of the *steady-state* MAC with the weight already resident.
//
// psum_in is held at zero so the observed leakage is attributable to the
// multiplier and the psum_out register, not to injected north traffic.
// Set +PSUM_RANDOM=1 to instead randomise the north partial sum, which
// isolates the adder/register leakage from the multiplier leakage.
//=====================================================================
module tb_tvla_pe;

    localparam N    = 8;
    localparam ACCW = 32;
    localparam real CLK_NS = 10.0;

    localparam OPS     = 8;
    localparam FLUSH   = 3;
    localparam CAPTURE = OPS + 1;         // +1 to clock out the last psum

    reg                     clk = 1'b0;
    reg                     reset_n, wt_load, valid_in;
    reg  signed [N-1:0]     wt_in, act_in;
    reg  signed [ACCW-1:0]  psum_in;
    wire                    valid_out;
    wire signed [N-1:0]     wt_out, act_out;
    wire signed [ACCW-1:0]  psum_out;

    // ---- Phase 2: masked DUT. Splitter + RNG are OUTSIDE the dumped scope
    // (u_dut only), like the weight load in the baseline (rule R4).
    integer MASK_EN_I;
    reg     mask_en = 1'b1;
    wire [ACCW-1:0] mk_r, mk_wt0, mk_wt1, m_wt0_o, m_wt1_o, m_ps0_o, m_ps1_o;
    mask_rng #(.W(ACCW), .SEED(64'd1)) u_rng (
        .clk(clk), .reset_n(reset_n), .advance(wt_load), .r(mk_r));
    weight_splitter #(.N(N), .SHARE_W(ACCW), .COLS(1)) u_split (
        .mask_en(mask_en), .wt_flat(wt_in), .r_flat(mk_r),
        .wt0_flat(mk_wt0), .wt1_flat(mk_wt1));

    (* dont_touch = "yes" *)
    processing_element_masked #(.N(N), .SHARE_W(ACCW)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
        .wt0_in(mk_wt0), .wt1_in(mk_wt1),
        .valid_in(valid_in), .act_in(act_in),
        .psum0_in({ACCW{1'b0}}), .psum1_in(psum_in),   // psum_in is PUBLIC here
        .valid_out(valid_out), .wt0_out(m_wt0_o), .wt1_out(m_wt1_o),
        .act_out(act_out), .psum0_out(m_ps0_o), .psum1_out(m_ps1_o));


    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    integer PSUM_RANDOM;
    reg signed [N-1:0] secret_wt;            // resident weight, fixed for the run
    reg signed [N-1:0] fix_act [0:OPS-1];

    integer t, k;
    reg grp, eff;
    reg signed [N-1:0]    ra, rw;
    reg signed [ACCW-1:0] rps;

    initial begin
        sca_get_config("pe_masked");
        if (!$value$plusargs("MASK_EN=%d", MASK_EN_I)) MASK_EN_I = 1;
        mask_en = (MASK_EN_I != 0);
        $display("[MASK] mask_en=%0d", mask_en);
        if (!$value$plusargs("PSUM_RANDOM=%d", PSUM_RANDOM)) PSUM_RANDOM = 0;

        secret_wt = rand_i8(0);
        for (k = 0; k < OPS; k = k + 1) fix_act[k] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);

        sca_open_meta("processing_element_masked", CLK_NS, CAPTURE);

        reset_n  = 1'b0; wt_load = 1'b0; valid_in = 1'b0;
        wt_in    = {N{1'b0}}; act_in = {N{1'b0}}; psum_in = {ACCW{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- weight load, untriggered (R4) ----
            // For TVLA_TARGET="wt" the weight is the varying quantity, so
            // it is reloaded every trace; for "act" the same secret weight
            // is reloaded every trace to keep the pipeline state identical.
            rw = rand_i8(0);
            @(negedge clk);
            wt_load = 1'b1;
            if (TVLA_TARGET == "wt" && eff) wt_in = rw;
            else                            wt_in = secret_wt;
            @(posedge clk);
            @(negedge clk);
            wt_load = 1'b0;
            wt_in   = {N{1'b0}};

            // ---- flush, untriggered ----
            valid_in = 1'b0; act_in = {N{1'b0}}; psum_in = {ACCW{1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < OPS; k = k + 1) begin
                @(negedge clk);          // drive off the negedge (see note)
                ra  = rand_i8(0);
                rps = {rand_word(ACCW)};
                if (!eff) ra = fix_act[k];

                if (TVLA_TARGET == "wt") act_in = fix_act[k];
                else                     act_in = ra;

                psum_in  = PSUM_RANDOM ? rps : {ACCW{1'b0}};
                valid_in = 1'b1;
                @(posedge clk);
                if (k == 0) sca_trace_begin;
            end

            @(negedge clk);
            valid_in = 1'b0; act_in = {N{1'b0}}; psum_in = {ACCW{1'b0}};
            @(posedge clk);                     // drain psum_out
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
