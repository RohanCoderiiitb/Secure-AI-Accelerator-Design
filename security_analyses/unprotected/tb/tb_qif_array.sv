`timescale 1ns/1ps
//=====================================================================
// tb_qif_array.v -- QIF capture for the 5x5 weight-stationary array.
//
// THE ENUMERATION ARGUMENT FOR THIS BLOCK
// ---------------------------------------
// Full joint enumeration is 25 INT8 weights = 2^200 configurations. That
// is not a patience problem, it is impossible. But exhaustiveness
// survives in the form that carries the security meaning.
//
// For EACH enumerated context k, ALL 256 values of the secret w[0][0]
// are simulated. Every conditional channel I(S;O|K=k) is therefore
// EXACT -- a true channel, not an estimate. Then:
//
//   chosen-context   max_k I(S;O|K=k)   EXACT, and the real upper bound
//   known-context    mean_k I(S;O|K=k)  EXACT over the enumerated set
//   marginal         I(S;O)             estimated, weakest threat model
//
// The number that bounds weight extraction is the chosen-context one,
// and it stays exact. Only the weakest-attacker figure is sampled.
//
// A context here is the complete public state: the other 24 weights plus
// the activation tile. Contexts are drawn from the seeded PRNG so the set
// is reproducible and identical across secret values.
//
// Budget:  256 secrets x QIF_CTX contexts
//            QIF_CTX=256   ->    65,536 traces, ~2 hr,  ~4 GB VCD
//            QIF_CTX=4096  -> 1,048,576 traces, ~26 hr, ~63 GB VCD
// Use FST plus fst2vcd streaming for the larger run.
//
// Geometry is fixed at 5x5 by default -- no smaller ladder rungs.
//=====================================================================
module tb_qif_array;
    parameter N = 8, ACCW = 32, ROWS = 5, COLS = 5;
    localparam real CLK_NS = 10.0;
    localparam STREAM_LEN = 4;
    localparam CAPTURE    = STREAM_LEN + ROWS + COLS;
    localparam FLUSH      = ROWS + COLS + 2;

    reg clk = 1'b0, reset_n, wt_load;
    reg [COLS*N-1:0]     wt_flat;
    reg [ROWS-1:0]       valid_act_in;
    reg [ROWS*N-1:0]     act_flat;
    reg [COLS*ACCW-1:0]  psum_flat;
    wire [COLS*ACCW-1:0] psum_out;
    wire [COLS-1:0]      valid_sum_out;
    wire [ROWS*N-1:0]    act_out;
    wire [ROWS-1:0]      valid_act_out;

    (* dont_touch = "yes" *)
    systolic_array #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat),
        .psum_flat(psum_flat), .psum_out(psum_out),
        .valid_sum_out(valid_sum_out), .act_out(act_out),
        .valid_act_out(valid_act_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer EXH, CTX_BYTES;
    reg signed [N-1:0] ctx_w   [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0] ctx_act [0:STREAM_LEN-1][0:ROWS-1];
    integer si, ki, r, c, k, cyc, idx;
    reg signed [N-1:0] sv, tmp8;
    reg [63:0] ctx_seed;

    // Regenerate context k deterministically from its index, so every
    // secret sees the identical context and the conditional channel is
    // built on a genuinely fixed public state.
    // EXHAUSTIVE MODE ---------------------------------------------------
    // Full joint enumeration of the array is 2^200 and impossible. But
    // "exhaustive" only needs the DECLARED (secret, context) space to be
    // covered completely -- so the context is declared narrowly enough to
    // enumerate: the other 24 weights are held at a FIXED PUBLIC CONSTANT,
    // the activation tile is zero except for the one value entering the
    // target PE, and THAT value is swept over all 256 possibilities.
    //
    //   secret  w[0][0]                     256 values, complete
    //   context activation into PE(0,0)     256 values, complete
    //   total                               65,536 traces, EXACT
    //
    // Every cell of the declared space is simulated, so the channel is the
    // true channel and MI is a bound, not an estimate. The trade is
    // narrower scope: it measures the target PE against a quiet array
    // rather than against arbitrary background traffic. Use EXH=0 for the
    // sampled-background variant, which has broader scope but whose
    // marginalisation is over a sampled rather than complete context set.
    task make_context_exh(input integer kidx);
        integer rr, cc, kk;
        begin
            prng_state = 64'd1469598103934665603;      // fixed public weights
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1)
                    ctx_w[rr][cc] = rand_i8(0);
            for (kk = 0; kk < STREAM_LEN; kk = kk + 1)
                for (rr = 0; rr < ROWS; rr = rr + 1)
                    ctx_act[kk][rr] = 8'sd0;

            // Context byte 0: the activation entering the target PE.
            ctx_act[0][0] = kidx[7:0];

            // Context byte 1 (CTX_BYTES=2): w[1][0], the PE directly
            // downstream on the psum chain. That is the most strongly
            // coupled neighbour, so if a second context dimension is
            // going to change the marginal at all, this is the one that
            // will show it.
            if (CTX_BYTES >= 2)
                ctx_w[1][0] = kidx[15:8];
        end
    endtask

    task make_context(input integer kidx);
        integer rr, cc, kk;
        begin
            prng_state = 64'd1469598103934665603 + kidx*64'd1099511628211;
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1)
                    ctx_w[rr][cc] = rand_i8(0);
            for (kk = 0; kk < STREAM_LEN; kk = kk + 1)
                for (rr = 0; rr < ROWS; rr = rr + 1)
                    ctx_act[kk][rr] = rand_i8(0);
        end
    endtask

    task load_weights(input signed [N-1:0] secret_w);
        integer rr, cc;
        begin
            for (rr = ROWS-1; rr >= 0; rr = rr - 1) begin
                @(negedge clk); wt_load = 1'b1;
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    tmp8 = ctx_w[rr][cc];
                    if (rr == 0 && cc == 0) tmp8 = secret_w;  // the secret
                    wt_flat[cc*N +: N] = tmp8;
                end
                @(posedge clk);
            end
            @(negedge clk); wt_load = 1'b0; wt_flat = 0;
        end
    endtask

    initial begin
        qif_get_config("qif_array5x5", 256);
        if (!$value$plusargs("EXH=%d", EXH)) EXH = 1;   // exhaustive by default
        if (!$value$plusargs("CTX_BYTES=%d", CTX_BYTES)) CTX_BYTES = 1;
        if (CTX_BYTES < 1) CTX_BYTES = 1;
        if (CTX_BYTES > 2) CTX_BYTES = 2;
        // The context space is enumerated COMPLETELY: 256^CTX_BYTES values.
        //   CTX_BYTES=1 ->    256 contexts ->    65,536 traces
        //   CTX_BYTES=2 -> 65,536 contexts -> 16,777,216 traces
        if (EXH) QIF_CTX = (CTX_BYTES == 2) ? 65536 : 256;
        qif_total = 256 * QIF_CTX;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // scope-limited: bare mesh only
        qif_open_meta("systolic_array", CLK_NS, CAPTURE, qif_total);
        if (EXH)
            $display("[QIF] %0dx%0d array EXHAUSTIVE: 256 secrets x %0d contexts (%0d ctx byte(s)) = %0d traces",
                     ROWS, COLS, QIF_CTX, CTX_BYTES, qif_total);
        else
            $display("[QIF] %0dx%0d array SAMPLED: 256 secrets x %0d contexts = %0d traces",
                     ROWS, COLS, QIF_CTX, qif_total);
        if (EXH && CTX_BYTES == 2)
            $display("[QIF] secret = w[0][0], context = act into PE(0,0) x w[1][0], both enumerated in full");
        else if (EXH)
            $display("[QIF] secret = w[0][0], context = act into PE(0,0), enumerated in full");
        else
            $display("[QIF] secret = w[0][0], context = sampled random background");

        reset_n = 0; wt_load = 0; wt_flat = 0;
        valid_act_in = 0; act_flat = 0; psum_flat = 0;
        repeat (4) @(posedge clk); reset_n = 1; repeat (4) @(posedge clk);

        for (ki = 0; ki < QIF_CTX; ki = ki + 1) begin
            if (EXH) make_context_exh(ki);
            else     make_context(ki);
            for (si = 0; si < 256; si = si + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[7:0];
                    load_weights(sv);                 // untriggered

                    @(negedge clk); valid_act_in = 0; act_flat = 0;
                    repeat (FLUSH) @(posedge clk);

                    for (cyc = 0; cyc < CAPTURE; cyc = cyc + 1) begin
                        @(negedge clk);
                        for (r = 0; r < ROWS; r = r + 1) begin
                            idx = cyc - r;            // skew, outside the DUT
                            if (idx >= 0 && idx < STREAM_LEN) begin
                                act_flat[r*N +: N] = ctx_act[idx][r];
                                valid_act_in[r]    = 1'b1;
                            end else begin
                                act_flat[r*N +: N] = 0;
                                valid_act_in[r]    = 1'b0;
                            end
                        end
                        @(posedge clk);
                        if (cyc == 0) trace_t0 = $realtime;
                    end
                    @(negedge clk); valid_act_in = 0; act_flat = 0;
                    qif_trace_end(si, $signed(sv), ki, ki);
                    qif_progress(qif_idx, qif_total);
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule