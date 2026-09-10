`timescale 1ns/1ps
//=====================================================================
// tb_qif_mult.v -- EXHAUSTIVE QIF capture for the Baugh-Wooley multiplier.
//
// Secret space:  y (weight)      256 values   -- IP category
// Context space: x (activation)  256 values
// Total:         65,536 traces, fully exhaustive over the joint space.
//
// Because the joint space is enumerated completely and the RTL map is
// deterministic, the resulting channel is the TRUE channel. I(S;O)
// carries no estimator bias and the reported bits are an exact bound.
//
// Run both secret assignments: SECRET=wt gives the IP-theft model,
// SECRET=act gives the input-privacy model. The proposal claims both.
//=====================================================================
module qif_mult_dut #(parameter N = 8)(
    input  wire clk, input wire reset_n, input wire en,
    input  wire signed [N-1:0] x_in, y_in,
    output reg  signed [2*N-1:0] p_out
);
    reg signed [N-1:0] x_r, y_r;
    wire      [2*N-1:0] p;
    (* dont_touch = "yes" *) (* use_dsp = "no" *)
    baugh_wooley_multiplier #(.N(N)) u_mul (.x(x_r), .y(y_r), .p(p));
    always @(posedge clk) begin
        if (!reset_n) begin x_r <= 0; y_r <= 0; p_out <= 0; end
        else if (en)  begin x_r <= x_in; y_r <= y_in; p_out <= p; end
    end
endmodule

module tb_qif_mult;
    localparam N = 8;
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 5;   // operand latch, product latch, drain          // latch operands, then latch product
    localparam FLUSH   = 3;

    reg clk = 1'b0, reset_n, en;
    reg signed [N-1:0] x_in, y_in;
    wire signed [2*N-1:0] p_out;

    qif_mult_dut #(.N(N)) u_dut (.clk(clk), .reset_n(reset_n), .en(en),
                                 .x_in(x_in), .y_in(y_in), .p_out(p_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    string SECRET;
    integer si, ki;
    reg signed [N-1:0] sv, kv;

    initial begin
        qif_get_config("qif_mult", 256);
        if (!$value$plusargs("SECRET=%s", SECRET)) SECRET = "wt";

        qif_total = 256*256;
        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        qif_open_meta("mult_dut", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] exhaustive 256 secrets x 256 contexts = %0d traces, secret=%0s",
                 qif_total, SECRET);

        reset_n = 1'b0; en = 1'b0; x_in = 0; y_in = 0;
        repeat (4) @(posedge clk); reset_n = 1'b1; repeat (4) @(posedge clk);

        for (si = 0; si < 256; si = si + 1) begin
            for (ki = 0; ki < 256; ki = ki + 1) begin
                if (qif_past_slice(qif_idx)) begin
                    sca_close_meta; $finish;
                end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[7:0];       // secret value, full INT8 range
                    kv = ki[7:0];       // context value

                    @(negedge clk);
                    en = 1'b1; x_in = 0; y_in = 0;
                    repeat (FLUSH) @(posedge clk);

                    @(negedge clk);
                    if (SECRET == "act") begin x_in = sv; y_in = kv; end
                    else                 begin x_in = kv; y_in = sv; end
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); x_in = 0; y_in = 0;
                    repeat (CAPTURE-1) @(posedge clk);   // drain the pipeline
                    qif_trace_end(si, $signed(sv), ki, $signed(kv));
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end
        en = 1'b0; repeat (2) @(posedge clk);
        sca_close_meta; $finish;
    end
endmodule
