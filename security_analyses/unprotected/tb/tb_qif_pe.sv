`timescale 1ns/1ps
//=====================================================================
// tb_qif_pe.v -- EXHAUSTIVE QIF capture for the weight-stationary PE.
//
// Secret:  wt_reg  256 values (IP)   or act_in 256 values (privacy)
// Context: the other operand, 256 values
// psum_in: held at 0. Enumerating it would multiply the space by the
//          reachable psum range (~2^18) and push this to ~10^9 traces.
//          The PE number is therefore reported as conditional on
//          psum_in = 0, and the psum contribution is measured separately
//          in tb_qif_psum.v. State that conditioning when quoting it.
//
// Total: 65,536 traces, exhaustive. The weight load sits OUTSIDE the
// capture window -- loading pushes the secret through wt_reg directly and
// would give a trivially maximal, operationally irrelevant channel.
//=====================================================================
module tb_qif_pe;
    localparam N = 8, ACCW = 32;
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 4;   // MAC latch, psum/act propagate, drain
    localparam FLUSH   = 3;

    reg clk = 1'b0, reset_n, wt_load, valid_in;
    reg signed [N-1:0] wt_in, act_in;
    reg signed [ACCW-1:0] psum_in;
    wire valid_out; wire signed [N-1:0] wt_out, act_out;
    wire signed [ACCW-1:0] psum_out;

    (* dont_touch = "yes" *)
    processing_element #(.N(N), .ACCW(ACCW)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_in(wt_in),
        .valid_in(valid_in), .act_in(act_in), .psum_in(psum_in),
        .valid_out(valid_out), .wt_out(wt_out), .act_out(act_out),
        .psum_out(psum_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    string SECRET;
    integer si, ki;
    reg signed [N-1:0] sv, kv, wv, av;

    initial begin
        qif_get_config("qif_pe", 256);
        if (!$value$plusargs("SECRET=%s", SECRET)) SECRET = "wt";
        qif_total = 256*256;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        qif_open_meta("processing_element", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] exhaustive %0d traces, secret=%0s, psum_in=0", qif_total, SECRET);

        reset_n = 0; wt_load = 0; valid_in = 0;
        wt_in = 0; act_in = 0; psum_in = 0;
        repeat (4) @(posedge clk); reset_n = 1; repeat (4) @(posedge clk);

        for (si = 0; si < 256; si = si + 1) begin
            for (ki = 0; ki < 256; ki = ki + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[7:0]; kv = ki[7:0];
                    if (SECRET == "act") begin av = sv; wv = kv; end
                    else                 begin wv = sv; av = kv; end

                    // weight load, untriggered
                    @(negedge clk); wt_load = 1'b1; wt_in = wv;
                    @(posedge clk);
                    @(negedge clk); wt_load = 1'b0; wt_in = 0;
                    valid_in = 1'b0; act_in = 0; psum_in = 0;
                    repeat (FLUSH) @(posedge clk);

                    // capture window: one MAC
                    @(negedge clk); act_in = av; valid_in = 1'b1;
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); act_in = 0; valid_in = 1'b0;
                    repeat (CAPTURE-1) @(posedge clk);   // propagate and drain
                    qif_trace_end(si, $signed(sv), ki, $signed(kv));
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
