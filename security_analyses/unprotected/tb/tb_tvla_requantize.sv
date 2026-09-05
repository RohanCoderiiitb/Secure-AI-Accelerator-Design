`timescale 1ns/1ps
//=====================================================================
// tb_tvla_requantize.v -- TVLA dataset generation for the 3-stage
//                          requantization pipeline.
//
// Pipeline stages:
//   Stage 1 (cycle 0): acc_in + bias_in  → biased_s1   (ACCW bits)
//   Stage 2 (cycle 1): biased_s1 * m0_s1 → prod_s2     (PW = 64 bits)
//   Stage 3 (cycle 2): round + shift + clamp → q_out / sat_out
//
// Leakage surfaces in order of expected magnitude:
//   1. prod_s2 (64-bit multiply result) — largest HD, dominant
//   2. biased_s1 (32-bit bias-added accumulator)
//   3. q_out (8-bit clamped output)
//   4. sat_out (1-bit clamp oracle — a very clean 0/1 branch)
//
// Fixed/random contrast is on acc_in (the accumulated dot product,
// i.e. the secret inference data). m0_in, shift_in and bias_in are
// per-layer public constants, held identical in both populations.
//
// CAPTURE = OPS + DRAIN: OPS inputs are pushed, then DRAIN zero-valid
// cycles let the last result clock through all 3 stages.
//
// TVA_TARGET choices:
//   "act"  : acc_in varies (random) vs fixed — default, models weight-
//             stationary attack where the attacker controls activations
//   "m0"   : m0_in varies — models an IP-extraction attack trying to
//             recover the per-layer scale factor
//=====================================================================
module tb_tvla_requantize;

    localparam N    = 8;
    localparam ACCW = 32;
    localparam MW   = 32;
    localparam SW   = 6;
    localparam PW   = ACCW + MW;   // 64

    localparam real CLK_NS = 10.0;

    localparam OPS     = 8;        // inputs per trace
    localparam DRAIN   = 3;        // pipeline depth
    localparam CAPTURE = OPS + DRAIN;
    localparam FLUSH   = DRAIN + 2;

    reg                    clk = 1'b0;
    reg                    reset_n, valid_in;
    reg  signed [ACCW-1:0] acc_in, bias_in;
    reg  signed [MW-1:0]   m0_in;
    reg  [SW-1:0]          shift_in;
    wire                   valid_out, sat_out;
    wire [N-1:0]           q_out;

    (* dont_touch = "yes" *)
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .acc_in(acc_in), .bias_in(bias_in),
        .m0_in(m0_in), .shift_in(shift_in),
        .valid_out(valid_out), .q_out(q_out), .sat_out(sat_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    // Fixed population: representative accumulator magnitudes.
    // Drawn from the seeded PRNG so the value is reproducible but not
    // degenerate (not all-zero, not max-positive).
    reg signed [ACCW-1:0] fix_acc [0:OPS-1];

    // Accumulator magnitudes consistent with a length-5 INT8 dot product
    // plus bias: roughly ±2^17. Using full 32-bit range would put almost
    // every result in saturation, which is a valid but uninteresting case.
    function signed [ACCW-1:0] rand_acc(input integer dummy);
        reg [63:0] r;
        begin
            r        = xs64s(0);
            rand_acc = $signed({{(ACCW-18){r[17]}}, r[17:0]});
        end
    endfunction

    // m0 in Q0.31 format — same range as TFLite's effective multiplier.
    function signed [MW-1:0] rand_m0(input integer dummy);
        reg [63:0] r;
        begin
            r       = xs64s(0);
            rand_m0 = $signed({1'b0, r[30:0]});   // positive, < 1 in Q0.31
        end
    endfunction

    integer t, k;
    reg grp, eff;
    reg signed [ACCW-1:0] ra;
    reg signed [MW-1:0]   rm;

    initial begin
        sca_get_config("requantize");

        // Public per-layer constants held fixed across both populations
        bias_in  = 32'sd137;
        m0_in    = 32'sh4E8B_1C00;   // ≈ 0.618 in Q0.31
        shift_in = 6'd9;

        for (k = 0; k < OPS; k = k + 1) fix_acc[k] = rand_acc(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        sca_open_meta("requantize", CLK_NS, CAPTURE);

        reset_n = 1'b0; valid_in = 1'b0; acc_in = {ACCW{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (6) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush pipeline, untriggered ----
            @(negedge clk);
            valid_in = 1'b0; acc_in = {ACCW{1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < CAPTURE; k = k + 1) begin
                @(negedge clk);
                if (k < OPS) begin
                    // R5: always draw from PRNG for both groups
                    ra = rand_acc(0);
                    rm = rand_m0(0);
                    if (!eff) ra = fix_acc[k];

                    if (TVLA_TARGET == "m0") begin
                        // vary the scale factor, hold acc fixed
                        acc_in   = fix_acc[k];
                        m0_in    = eff ? rm : 32'sh4E8B_1C00;
                    end else begin
                        // default "act": vary acc_in
                        acc_in   = ra;
                    end
                    valid_in = 1'b1;
                end else begin
                    valid_in = 1'b0;   // drain
                    acc_in   = {ACCW{1'b0}};
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
