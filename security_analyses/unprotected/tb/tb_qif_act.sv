`timescale 1ns/1ps
//=====================================================================
// tb_qif_act.v -- EXHAUSTIVE QIF for the activation unit.
//
// Secret category depends on SECRET=:
//   "act"   x_in, 256 values          -- input privacy
//   "mode"  mode, 4 values            -- TOPOLOGY / architecture
//
// The mode secret is the interesting one. It is not data, it is network
// architecture, and I(mode;O) directly bounds architecture recovery --
// the thing CSI NN extracts empirically via EM. Bounding it in bits from
// RTL is a stronger statement than an empirical attack.
//
// Total 1024 traces (256 x_in x 4 modes). Fully exhaustive in seconds.
//=====================================================================
module tb_qif_act;
    localparam N = 8;
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 4, FLUSH = 4;   // y_out latch, hold, drain

    reg clk = 1'b0, reset_n, valid_in;
    reg [1:0] mode;
    reg signed [N-1:0] x_in, clamp_high;
    reg [2:0] leaky_shift;
    wire valid_out; wire signed [N-1:0] y_out;

    (* dont_touch = "yes" *)
    activation_unit #(.N(N)) u_dut (
        .clk(clk), .reset_n(reset_n), .mode(mode), .valid_in(valid_in),
        .x_in(x_in), .clamp_high(clamp_high), .leaky_shift(leaky_shift),
        .valid_out(valid_out), .y_out(y_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    string SECRET;
    integer si, ki;
    reg signed [N-1:0] xv;
    reg [1:0] mv;

    initial begin
        qif_get_config("qif_act", 4);
        if (!$value$plusargs("SECRET=%s", SECRET)) SECRET = "act";
        clamp_high = 8'sd127; leaky_shift = 3'd3;
        qif_total = 256*4;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        qif_open_meta("activation_unit", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] exhaustive %0d traces (256 x_in x 4 modes), secret=%0s",
                 qif_total, SECRET);

        reset_n = 0; valid_in = 0; x_in = 0; mode = 0;
        repeat (4) @(posedge clk); reset_n = 1; repeat (4) @(posedge clk);

        for (si = 0; si < 256; si = si + 1) begin
            for (ki = 0; ki < 4; ki = ki + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    xv = si[7:0]; mv = ki[1:0];
                    @(negedge clk); valid_in = 0; x_in = 0; mode = mv;
                    repeat (FLUSH) @(posedge clk);
                    @(negedge clk); x_in = xv; valid_in = 1'b1;
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); x_in = 0; valid_in = 0;
                    repeat (CAPTURE-1) @(posedge clk);   // hold and drain
                    // secret/context roles swap so one capture serves both
                    if (SECRET == "mode")
                        qif_trace_end(ki, ki, si, $signed(xv));
                    else
                        qif_trace_end(si, $signed(xv), ki, ki);
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
