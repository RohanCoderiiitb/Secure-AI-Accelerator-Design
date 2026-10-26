`timescale 1ns/1ps
//=====================================================================
// tb_tvla_masked_act_pe.sv -- TVLA dataset generation for the
//                             activation-masked processing element
//                             (protected_designs/source/processing_element_masked_act.sv)
//
// Secret under test: the ACTIVATION. The weight is plain (public) and
// held in the PE; psum inputs are tied to zero so the leakage is
// attributable to the multiplier pair and the psum / act-share registers.
//
// Exhaustive coverage (default N = 131072 = 2 x 65536), same scheme as
// tvla_tb_masked_act_multiplier.sv:
//   RANDOM group : every (weight, activation) pair once, shuffled
//   FIXED  group : the fixed activation (+FIXED_A) with every weight,
//                  each weight 256 times, shuffled
// Both groups see the same weight distribution; only the activation differs.
//
// Masking (done here, OUTSIDE the dumped scope u_dut), EVERY cycle:
//   m random 32-bit, act0 = sext(a) - m, act1 = m
// The FIXED group uses a fixed VALUE with fresh shares, never fixed shares.
// R5: exactly one PRNG word is drawn per share_act call, whatever the group.
//
// Extra plusargs
//   +FIXED_A=<int>  fixed activation, signed decimal (default 93)
//   +MASK_OFF=1     m = 0: sanity control, first-order TVLA MUST detect
//   TVLA_TARGET must be "act" (the weight is public in this design)
//
// Per-trace timing (clock 10 ns, stimulus on the negedge):
//   weight load  1 cycle  untriggered, activation shares of 0   (rule R4)
//   flush        FLUSH    untriggered, shares of 0, valid = 0
//   cyc 0..OPS-1 activation shares of a_val, re-masked every cycle, valid = 1
//   drain        1 cycle  activation 0, last psum is clocked out
//=====================================================================
module tb_tvla_masked_act_pe;

    localparam N       = 8;
    localparam SW      = 32;
    localparam real CLK_NS = 10.0;
    localparam FLUSH   = 3;
    localparam OPS     = 3;
    localparam CAPTURE = OPS + 1;
    localparam NPAIRS  = 65536;

    reg                  clk = 1'b0;
    reg                  reset_n, wt_load, valid_in;
    reg  signed [N-1:0]  wt_in;
    reg  [SW-1:0]        act0_in, act1_in;
    wire                 valid_out;
    wire signed [N-1:0]  wt_out;
    wire [SW-1:0]        act0_out, act1_out, psum0_out, psum1_out;

    (* dont_touch = "yes" *)
    processing_element_masked_act #(.N(N), .SHARE_W(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_in(wt_in),
        .valid_in(valid_in), .act0_in(act0_in), .act1_in(act1_in),
        .psum0_in({SW{1'b0}}), .psum1_in({SW{1'b0}}),     // psum_in = public 0
        .valid_out(valid_out), .wt_out(wt_out),
        .act0_out(act0_out), .act1_out(act1_out),
        .psum0_out(psum0_out), .psum1_out(psum1_out));

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg [15:0] list_r [0:NPAIRS-1];   // random group: {w, a}, all 65536 pairs
    reg [15:0] list_f [0:NPAIRS-1];   // fixed group: low byte = weight, 256 times each

    integer t, i, j, k, idx_r, idx_f, mask_off, fixed_a_int, n_cov_r, n_cov_f;
    reg     grp, eff;
    reg [15:0]   tmp, pair;
    reg [N-1:0]  a_val, w_val, fixed_a;
    reg [63:0]   rw;
    reg [SW-1:0] m;

    // activation -> two shares; always exactly one PRNG word (R5)
    task share_act(input [N-1:0] a);
        begin
            rw      = rand_word(SW);
            m       = mask_off ? {SW{1'b0}} : rw[SW-1:0];
            act0_in = {{(SW-N){a[N-1]}}, a} - m;
            act1_in = m;
        end
    endtask

    task shuffle_lists;
        begin
            for (i = 0; i < NPAIRS; i = i + 1) begin
                list_r[i] = i[15:0];
                list_f[i] = i[15:0];
            end
            for (i = NPAIRS - 1; i > 0; i = i - 1) begin
                j = xs64s(0) % (i + 1);
                tmp = list_r[i]; list_r[i] = list_r[j]; list_r[j] = tmp;
                j = xs64s(0) % (i + 1);
                tmp = list_f[i]; list_f[i] = list_f[j]; list_f[j] = tmp;
            end
        end
    endtask

    initial begin
        sca_get_config("masked_act_pe");
        if (TVLA_TARGET != "act") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- only 'act' is meaningful (weight is public here)", TVLA_TARGET);
            $finish;
        end
        if (!$value$plusargs("MASK_OFF=%d", mask_off))    mask_off    = 0;
        if (!$value$plusargs("FIXED_A=%d",  fixed_a_int)) fixed_a_int = 93;
        fixed_a = fixed_a_int[N-1:0];

        shuffle_lists;
        idx_r = 0; idx_f = 0;
        $display("[SCA] activation-masked PE: fixed_a=%0d mask_off=%0d, %0s",
                 $signed(fixed_a), mask_off,
                 (NTRACES >= 2*NPAIRS) ? "EXHAUSTIVE (all w x a pairs)"
                                       : "subset of the pair lists");

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: PE only

        sca_open_meta("masked_act_pe", CLK_NS, CAPTURE);

        reset_n = 1'b0; wt_load = 1'b0; valid_in = 1'b0;
        wt_in = 0; act0_in = 0; act1_in = 0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            if (eff) begin
                pair  = list_r[idx_r % NPAIRS];
                w_val = pair[15:8];
                a_val = pair[7:0];
            end else begin
                pair  = list_f[idx_f % NPAIRS];
                w_val = pair[7:0];
                a_val = fixed_a;
            end
            if (grp) idx_r = idx_r + 1; else idx_f = idx_f + 1;

            // ---- weight load, untriggered (R4) ----
            @(negedge clk);
            share_act(0); valid_in = 1'b0; wt_load = 1'b1; wt_in = w_val;
            @(posedge clk);
            @(negedge clk);
            wt_load = 1'b0; wt_in = 0;

            // ---- flush, untriggered ----
            share_act(0);
            repeat (FLUSH) begin
                @(posedge clk);
                @(negedge clk);
                share_act(0);
            end

            // ---- capture window ----
            for (k = 0; k < OPS; k = k + 1) begin
                share_act(a_val); valid_in = 1'b1;
                @(posedge clk);
                if (k == 0) sca_trace_begin;
                @(negedge clk);
            end

            // ---- drain: clock out the last psum ----
            share_act(0); valid_in = 1'b0;
            @(posedge clk);
            sca_trace_end(grp);

            if (t % 10000 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        n_cov_r = (idx_r < NPAIRS) ? idx_r : NPAIRS;
        n_cov_f = (idx_f < NPAIRS) ? idx_f : NPAIRS;
        $display("[SCA] coverage: random-label list %0d / %0d pairs, fixed-label list %0d / %0d",
                 n_cov_r, NPAIRS, n_cov_f, NPAIRS);

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
