`timescale 1ns/1ps
//=====================================================================
// tb_qif_mac.v -- QIF capture for the stand-alone MAC unit (MLP datapath).
//
// The MAC differs from the bare multiplier in exactly one way that
// matters here: the ACCUMULATOR. A single clr'd MAC step is essentially
// the multiplier channel with a wider output register. The interesting
// QIF question is how much the secret leaks once it is being folded into
// a running sum, because that is what an MLP layer actually does.
//
// Two enumeration modes, selected by +ACC_STEPS=:
//
//   ACC_STEPS=1  (default)  FULLY EXHAUSTIVE
//       clr asserted on the captured step, so accum <= prod.
//       S = wt (256) x K = act (256) = 65,536 traces, ~15 min.
//       Every cell of the joint space is simulated, so the channel is
//       the TRUE channel and MI is an exact bound.
//
//   ACC_STEPS=2             EXACT PER CONTEXT
//       One preceding accumulate step primes accum with a context
//       product, then the secret MAC is captured. The prior accumulator
//       state is part of the public context. Enumerating that jointly
//       with the secret is 2^32 and impossible, so instead: for EACH of
//       QIF_CTX enumerated priming pairs, ALL 256 secret values are
//       simulated. Every conditional channel I(S;O|K=k) is therefore
//       EXACT, and max_k of those is the chosen-context bound -- the
//       security-relevant number. Same structure as tb_qif_array.v.
//       Budget: 256 * QIF_CTX traces.
//
// SECRET=wt   the weight   -- IP category (MLP layer weights)
// SECRET=act  the input    -- privacy category
//
// The capture window covers only the accumulate step(s). The priming
// step in ACC_STEPS=2 sits OUTSIDE the window: it carries the context,
// not the secret, and including it would mix two operations into one
// observable.
//=====================================================================
module tb_qif_mac;

    localparam N    = 8;
    localparam ACCW = 32;
    localparam real CLK_NS = 10.0;

    localparam CAPTURE = 4;   // accumulate, accumulator holds, drain      // one accumulate step is the observable
    localparam FLUSH   = 3;

    reg                   clk = 1'b0;
    reg                   reset_n, en, clr;
    reg  signed [N-1:0]   act, wt;
    wire [ACCW-1:0]       accum;

    (* dont_touch = "yes" *)
    mac_unit #(.N(N), .ACCW(ACCW)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en), .clr(clr),
        .act(act), .wt(wt), .accum(accum)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer ACC_STEPS;
    string  SECRET;
    integer si, ki, nctx;
    reg signed [N-1:0] sv, kv, wv, av;
    reg signed [N-1:0] prime_a, prime_w;

    // Priming operands for context k, regenerated deterministically from
    // the index so every secret sees an identical prior accumulator state.
    task make_context(input integer kidx);
        begin
            prng_state = 64'd1469598103934665603 + kidx*64'd1099511628211;
            prime_a = rand_i8(0);
            prime_w = rand_i8(0);
        end
    endtask

    initial begin
        qif_get_config("qif_mac", 256);
        if (!$value$plusargs("SECRET=%s",    SECRET))    SECRET    = "wt";
        if (!$value$plusargs("ACC_STEPS=%d", ACC_STEPS)) ACC_STEPS = 1;

        nctx      = (ACC_STEPS == 1) ? 256 : QIF_CTX;
        qif_total = 256 * nctx;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: DUT only
        qif_open_meta("mac_unit", CLK_NS, CAPTURE, qif_total);

        if (ACC_STEPS == 1)
            $display("[QIF] mac ACC_STEPS=1: EXHAUSTIVE 256 secrets x 256 acts = %0d traces, secret=%0s",
                     qif_total, SECRET);
        else
            $display("[QIF] mac ACC_STEPS=2: 256 secrets x %0d priming contexts = %0d traces (each conditional exact), secret=%0s",
                     nctx, qif_total, SECRET);

        reset_n = 1'b0; en = 1'b0; clr = 1'b0;
        act = {N{1'b0}}; wt = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (ki = 0; ki < nctx; ki = ki + 1) begin
            if (ACC_STEPS != 1) make_context(ki);
            for (si = 0; si < 256; si = si + 1) begin

                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[7:0];
                    kv = ki[7:0];
                    if (SECRET == "act") begin av = sv; wv = kv; end
                    else                 begin wv = sv; av = kv; end

                    // ---- flush: zero the accumulator, untriggered ----
                    @(negedge clk);
                    en = 1'b1; clr = 1'b1; act = {N{1'b0}}; wt = {N{1'b0}};
                    @(posedge clk);
                    @(negedge clk); en = 1'b0; clr = 1'b0;
                    repeat (FLUSH) @(posedge clk);

                    if (ACC_STEPS == 1) begin
                        // ---- capture: single clr'd MAC, accum <= prod ----
                        @(negedge clk);
                        act = av; wt = wv; en = 1'b1; clr = 1'b1;
                        @(posedge clk);
                        trace_t0 = $realtime;
                    end else begin
                        // ---- priming step, UNTRIGGERED: context only ----
                        @(negedge clk);
                        act = prime_a; wt = prime_w; en = 1'b1; clr = 1'b1;
                        @(posedge clk);
                        // ---- capture: accumulate the secret onto it ----
                        @(negedge clk);
                        act = av; wt = wv; en = 1'b1; clr = 1'b0;
                        @(posedge clk);
                        trace_t0 = $realtime;
                    end

                    @(negedge clk);
                    en = 1'b0; clr = 1'b0;
                    act = {N{1'b0}}; wt = {N{1'b0}};
                    repeat (CAPTURE-1) @(posedge clk);   // accumulator holds, then drains

                    if (SECRET == "act")
                        qif_trace_end(si, $signed(sv), ki, $signed(kv));
                    else
                        qif_trace_end(si, $signed(sv), ki, $signed(kv));
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
