`timescale 1ns/1ps
//=====================================================================
// tb_qif_requant.v -- EXHAUSTIVE QIF over the REACHABLE acc_in range.
//
// acc_in is declared 32 bits, but with INT8 operands and ROWS=5 the
// accumulator can only reach 5*127*128 = 81,280 plus bias. Everything
// beyond +/-2^17 is unreachable. Sweeping the full 2^32 would take ~1.7
// years AND would be WRONG: it puts probability mass on states the
// hardware never occupies, distorting p(o|s) away from the true channel.
//
// So the sweep is exhaustive over ACC_LO..ACC_HI in steps of ACC_STEP:
//   default +/-2^17 with step 1 -> 262,144 traces, about an hour.
// Set +ACC_STEP=1 for the true exhaustive sweep; larger steps only for
// a quick smoke run.
//
// SECRET=acc   acc_in  -- input privacy (the layer's dot product)
// SECRET=m0    m0_in   -- TOPOLOGY: the per-layer scale factor is model
//                         metadata, and recovering it helps reconstruct
//                         the quantisation parameters of the network.
//=====================================================================
module tb_qif_requant;
    localparam N = 8, ACCW = 32, MW = 32, SW = 6;
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 6, FLUSH = 6;   // 3 pipeline stages + drain

    reg clk = 1'b0, reset_n, valid_in;
    reg signed [ACCW-1:0] acc_in, bias_in;
    reg signed [MW-1:0] m0_in;
    reg [SW-1:0] shift_in;
    wire valid_out, sat_out; wire [N-1:0] q_out;

    (* dont_touch = "yes" *)
    requantize #(.N(N), .ACCW(ACCW), .MW(MW), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .acc_in(acc_in), .bias_in(bias_in), .m0_in(m0_in),
        .shift_in(shift_in), .valid_out(valid_out), .q_out(q_out),
        .sat_out(sat_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer ACC_LO, ACC_HI, ACC_STEP, N_M0, M0_CTX;
    string SECRET;
    integer sv, ki, si, accv, span;
    reg signed [MW-1:0] m0v;

    initial begin
        qif_get_config("qif_requant", 1);
        if (!$value$plusargs("SECRET=%s",  SECRET))   SECRET   = "acc";
        if (!$value$plusargs("ACC_LO=%d",  ACC_LO))   ACC_LO   = -131072;
        if (!$value$plusargs("ACC_HI=%d",  ACC_HI))   ACC_HI   =  131071;
        if (!$value$plusargs("ACC_STEP=%d",ACC_STEP)) ACC_STEP = 1;
        if (!$value$plusargs("N_M0=%d",    N_M0))     N_M0     = 1;
        if (!$value$plusargs("M0_CTX=%d",  M0_CTX))   M0_CTX   = 256;

        bias_in = 32'sd137; shift_in = 6'd9; m0_in = 32'sh4E8B_1C00;
        span = ACC_HI - ACC_LO;

        if (SECRET == "m0") qif_total = 256 * M0_CTX;
        else                qif_total = ((ACC_HI - ACC_LO) / ACC_STEP + 1);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        qif_open_meta("requantize", CLK_NS, CAPTURE, qif_total);
        if (SECRET == "m0")
            $display("[QIF] m0 EXHAUSTIVE: 256 scale-factor values x %0d acc contexts = %0d traces",
                     M0_CTX, qif_total);
        else
            $display("[QIF] acc_in exhaustive over reachable [%0d,%0d] step %0d, %0d traces",
                     ACC_LO, ACC_HI, ACC_STEP, qif_total);

        reset_n = 0; valid_in = 0; acc_in = 0;
        repeat (4) @(posedge clk); reset_n = 1; repeat (6) @(posedge clk);

        if (SECRET == "m0") begin
            //-----------------------------------------------------------
            // TOPOLOGY secret: the per-layer scale factor.
            //
            // m0 is 32 bits, so the full space is not enumerable. The
            // secret here is its TOP BYTE, which carries essentially all
            // of the multiplier's magnitude information, and that byte is
            // swept EXHAUSTIVELY over all 256 values. acc_in becomes the
            // public context, sampled evenly across the reachable range.
            //
            // The earlier version drew m0 at random, which meant the
            // secret space was never fully covered and repeated top-byte
            // values collided in the channel. Enumeration fixes both.
            //-----------------------------------------------------------
            for (si = 0; si < 256; si = si + 1) begin
                m0v = $signed({1'b0, si[7:0], 23'd0});
                for (ki = 0; ki < M0_CTX; ki = ki + 1) begin
                    if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                    if (qif_in_slice(qif_idx)) begin
                        accv = ACC_LO + (ki * span) / M0_CTX;
                        @(negedge clk); valid_in = 0; acc_in = 0; m0_in = m0v;
                        repeat (FLUSH) @(posedge clk);
                        @(negedge clk); acc_in = accv; valid_in = 1'b1;
                        @(posedge clk);
                        trace_t0 = $realtime;
                        @(negedge clk); acc_in = 0; valid_in = 0;
                        repeat (CAPTURE-1) @(posedge clk);
                        qif_trace_end(si, si, ki, accv);
                        qif_progress(qif_idx, qif_total);
                    end
                    qif_idx = qif_idx + 1;
                end
            end
        end else begin
            //-----------------------------------------------------------
            // PRIVACY secret: the accumulated dot product, swept
            // exhaustively over every reachable value. m0/shift/bias are
            // public per-layer constants, so there is no context
            // dimension and the marginal model is the only model.
            //-----------------------------------------------------------
            m0_in = 32'sh4E8B_1C00;
            for (sv = ACC_LO; sv <= ACC_HI; sv = sv + ACC_STEP) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    @(negedge clk); valid_in = 0; acc_in = 0;
                    repeat (FLUSH) @(posedge clk);
                    @(negedge clk); acc_in = sv; valid_in = 1'b1;
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); acc_in = 0; valid_in = 0;
                    repeat (CAPTURE-1) @(posedge clk);
                    qif_trace_end(0, sv, -1, -1);
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule