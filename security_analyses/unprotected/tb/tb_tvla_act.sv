`timescale 1ns/1ps
//=====================================================================
// tb_tvla_act.v -- TVLA dataset generation for the activation unit.
//
// Pipeline: x_in → y_comb (combinational) → y_out (1 register, 1 cycle)
//
// Leakage surfaces:
//   y_out register: HD = popcount(y_out_new XOR y_out_old)
//   y_comb net:     combinational toggle — mode-dependent branching
//
// The activation function is a STRONG leakage source because:
//   ReLU      — y_out is all-zeros whenever x_in < 0. The fixed
//               population produces a known pattern; the random
//               population produces a mixture. The mean difference
//               is ~50% of the signal range.
//   ReLU-clip — same as ReLU plus an upper clamp that creates a
//               second branch oracle.
//   Leaky-ReLU — arithmetic right-shift of the negative half; the
//               shifted value leaks both magnitude and sign.
//   Pass      — pure wiring, y_out = x_in. Leakage is pure HD on
//               the input distribution.
//
// MODE plusarg selects the activation function at runtime:
//   +ACT_MODE=0   PASS        (baseline)
//   +ACT_MODE=1   RELU        (default — most relevant for CNN/MLP)
//   +ACT_MODE=2   RELU_CLIP
//   +ACT_MODE=3   LEAKY_RELU
//
// Run all four modes to get a complete leakage profile:
//   vvp build/tb_act.vvp +ACT_MODE=0 +TAG=act_pass  +NTRACES=2000
//   vvp build/tb_act.vvp +ACT_MODE=1 +TAG=act_relu  +NTRACES=2000
//   vvp build/tb_act.vvp +ACT_MODE=2 +TAG=act_clip  +NTRACES=2000
//   vvp build/tb_act.vvp +ACT_MODE=3 +TAG=act_leaky +NTRACES=2000
//=====================================================================
module tb_tvla_act;

    localparam N = 8;
    localparam real CLK_NS = 10.0;

    // 1-cycle pipeline: one extra cycle to drain y_out.
    localparam OPS     = 12;
    localparam DRAIN   = 1;
    localparam CAPTURE = OPS + DRAIN;
    localparam FLUSH   = 3;

    reg              clk = 1'b0;
    reg              reset_n, valid_in;
    reg  [1:0]       mode;
    reg  signed [N-1:0] x_in, clamp_high;
    reg  [2:0]       leaky_shift;
    wire             valid_out;
    wire signed [N-1:0] y_out;

    (* dont_touch = "yes" *)
    activation_unit #(.N(N)) u_dut (
        .clk(clk), .reset_n(reset_n), .mode(mode),
        .valid_in(valid_in), .x_in(x_in),
        .clamp_high(clamp_high), .leaky_shift(leaky_shift),
        .valid_out(valid_out), .y_out(y_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    integer ACT_MODE;
    reg signed [N-1:0] fix_x [0:OPS-1];

    integer t, k;
    reg grp, eff;
    reg signed [N-1:0] rx;

    initial begin
        sca_get_config("act");
        if (!$value$plusargs("ACT_MODE=%d", ACT_MODE)) ACT_MODE = 1;  // ReLU default

        mode        = ACT_MODE[1:0];
        clamp_high  = 8'sd127;   // ReLU6-style upper clamp at INT8 max
        leaky_shift = 3'd3;      // divide negative inputs by 8

        for (k = 0; k < OPS; k = k + 1) fix_x[k] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);

        sca_open_meta("activation_unit", CLK_NS, CAPTURE);
        $display("[SCA] ACT_MODE=%0d (%0s)",
            ACT_MODE,
            (ACT_MODE==0) ? "PASS" :
            (ACT_MODE==1) ? "RELU" :
            (ACT_MODE==2) ? "RELU_CLIP" : "LEAKY_RELU");

        reset_n = 1'b0; valid_in = 1'b0; x_in = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush, untriggered ----
            @(negedge clk);
            valid_in = 1'b0; x_in = {N{1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < CAPTURE; k = k + 1) begin
                @(negedge clk);
                if (k < OPS) begin
                    rx = rand_i8(0);            // R5: always draw
                    if (!eff) rx = fix_x[k];
                    x_in     = rx;
                    valid_in = 1'b1;
                end else begin
                    valid_in = 1'b0;            // drain
                    x_in     = {N{1'b0}};
                end
                @(posedge clk);
                if (k == 0) sca_trace_begin;
            end
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
