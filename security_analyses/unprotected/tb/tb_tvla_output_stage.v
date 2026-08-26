`timescale 1ns/1ps
//=====================================================================
// tb_tvla_output_stage.v -- TVLA dataset generation for the
//   requantize -> activation post-processing chain.
//
// Both blocks are dumped as one DUT scope because they form a single
// pipeline the attacker observes together, and because activation-unit
// leakage is conditioned on the requantizer's output distribution.
//
// The requantizer is the highest-leakage stage in the whole datapath
// by construction: the ACCWxMW multiply by m0 is a 64-bit product
// register whose HD tracks the accumulator value almost linearly, and
// the clamp comparison is an explicit data-dependent branch. The
// saturation flag sat_out is a one-bit oracle on |acc|.
//
// The fixed/random contrast is on acc_in, i.e. the layer's accumulated
// dot product. m0/shift/bias are per-layer public constants and are
// held identical across both populations.
//=====================================================================
module output_stage #(
    parameter N    = 8,
    parameter ACCW = 32,
    parameter MW   = 32,
    parameter SW   = 6
)(
    input  wire                   clk,
    input  wire                   reset_n,
    input  wire                   valid_in,
    input  wire signed [ACCW-1:0] acc_in,
    input  wire signed [ACCW-1:0] bias_in,
    input  wire signed [MW-1:0]   m0_in,
    input  wire        [SW-1:0]   shift_in,
    input  wire        [1:0]      act_mode,
    input  wire signed [N-1:0]    clamp_high,
    input  wire        [2:0]      leaky_shift,
    output wire                   valid_out,
    output wire signed [N-1:0]    y_out,
    output wire                   sat_out
);
    wire            rq_valid;
    wire [N-1:0]    rq_q;

    (* dont_touch = "yes" *)
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_rq (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .acc_in(acc_in), .bias_in(bias_in),
        .m0_in(m0_in), .shift_in(shift_in),
        .valid_out(rq_valid), .q_out(rq_q), .sat_out(sat_out)
    );

    (* dont_touch = "yes" *)
    activation_unit #(.N(N)) u_act (
        .clk(clk), .reset_n(reset_n),
        .mode(act_mode), .valid_in(rq_valid),
        .x_in($signed(rq_q)),
        .clamp_high(clamp_high), .leaky_shift(leaky_shift),
        .valid_out(valid_out), .y_out(y_out)
    );
endmodule


module tb_tvla_output_stage;

    localparam N    = 8;
    localparam ACCW = 32;
    localparam MW   = 32;
    localparam SW   = 6;
    localparam real CLK_NS = 10.0;

    localparam OPS     = 8;
    localparam FLUSH   = 5;
    localparam CAPTURE = OPS + 4;      // 3 requantize stages + 1 activation

    reg                    clk = 1'b0;
    reg                    reset_n, valid_in;
    reg  signed [ACCW-1:0] acc_in, bias_in;
    reg  signed [MW-1:0]   m0_in;
    reg  [SW-1:0]          shift_in;
    reg  [1:0]             act_mode;
    reg  signed [N-1:0]    clamp_high;
    reg  [2:0]             leaky_shift;
    wire                   valid_out, sat_out;
    wire signed [N-1:0]    y_out;

    output_stage #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .acc_in(acc_in), .bias_in(bias_in),
        .m0_in(m0_in), .shift_in(shift_in),
        .act_mode(act_mode), .clamp_high(clamp_high), .leaky_shift(leaky_shift),
        .valid_out(valid_out), .y_out(y_out), .sat_out(sat_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [ACCW-1:0] fix_acc [0:OPS-1];
    integer t, k;
    reg grp, eff;
    reg signed [ACCW-1:0] ra;

    // Accumulator magnitudes consistent with a length-ROWS INT8 dot
    // product plus bias: roughly +/-2^17, not uniform over 32 bits.
    function signed [ACCW-1:0] rand_acc(input integer dummy);
        reg [63:0] r;
        begin
            r        = xs64s(0);
            rand_acc = $signed({{(ACCW-18){r[17]}}, r[17:0]});
        end
    endfunction

    initial begin
        sca_get_config("outstage");

        for (k = 0; k < OPS; k = k + 1) fix_acc[k] = rand_acc(0);

        // Per-layer public constants: tflite-style M0 in Q0.31 and shift.
        bias_in     = 32'sd137;
        m0_in       = 32'sh4E8B_1C00;
        shift_in    = 6'd9;
        act_mode    = 2'd1;              // ReLU
        clamp_high  = 8'sd127;
        leaky_shift = 3'd3;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);

        sca_open_meta("output_stage", CLK_NS, CAPTURE);

        reset_n = 1'b0; valid_in = 1'b0; acc_in = {ACCW{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (6) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush the 4-deep pipeline, untriggered ----
            @(negedge clk);
            valid_in = 1'b0; acc_in = {ACCW{1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < CAPTURE; k = k + 1) begin
                @(negedge clk);          // drive off the negedge (see note)
                ra = rand_acc(0);
                if (k < OPS) begin
                    if (!eff) ra = fix_acc[k];
                    acc_in   = ra;
                    valid_in = 1'b1;
                end else begin
                    acc_in   = {ACCW{1'b0}};   // drain
                    valid_in = 1'b0;
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
