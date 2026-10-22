//=====================================================================
// tb_qif_systolic.sv -- QIF capture for systolic_array.sv (5x5 default,
// weight-stationary, no input skew / output deskew built into the RTL --
// see that file's own header comment).
//
// WHY MONTE CARLO, NOT EXHAUSTIVE ENUMERATION
// --------------------------------------------
// Unlike the earlier tb_qif_array.sv (FlexNN array), this testbench does
// NOT attempt to hold a narrow declared context exhaustive. The natural
// secret+context space here -- the OTHER 24 weight bytes plus 5
// activation bytes -- is far beyond enumerable (dwarfs even 2^200), so
// this testbench draws a FRESH, independently random background every
// single trace via rand_i8(), rather than a structured nested loop.
// qif_channel.build()'s existing exact-flag logic already handles this
// correctly with no changes needed: per-secret trace counts under random
// sampling will NOT come out exactly equal, so exact=False is set
// automatically, and the result is routed through qif_estimate.py's
// Miller-Madow correction + permutation null rather than trusted as a
// raw plug-in MI. Do not skip that step for this testbench's output.
//
// SECRET / CONTEXT
// -----------------
//   secret  : w[0][0], one INT8 weight -- IP-theft framing, matches
//             every other testbench's convention in this suite.
//   context : a[0], the ONE activation value directly multiplied with
//             the secret at PE[0][0] -- logged for future conditional
//             analysis, but the default marginal-MI reporting path
//             (qif_channel.marginal_channel / run_qif.py) ignores it,
//             exactly as for every other block in this suite.
//   background (untracked, no context_id of its own): the other 24
//             weight bytes and the other 4 activation bytes, drawn
//             fresh every trace. This is what makes the "too many
//             traces to enumerate" problem a NON-problem: it's treated
//             as genuine, unconditioned randomness (the attacker-does-
//             not-know-it threat model this whole suite already uses
//             for context), not something that needs its own sweep.
//
// STIMULUS PROTOCOL (VERIFIED, not just derived -- see note below)
// -------------------------------------------------------------------
// The RTL's own header states input skew / output deskew were
// deliberately left OUT of systolic_array.sv, specifically so that a
// shift-chain's switching activity never contaminates the analysis of
// the array's own switching. That means BOTH of the following are the
// testbench's responsibility, not the DUT's:
//
//   1. Weight load: wt_flat must be presented in REVERSE ROW ORDER over
//      ROWS consecutive wt_load pulses (row ROWS-1 first, row 0 last).
//      This falls out of wt_reg being a simple one-PE-per-pulse vertical
//      shift register fed from row 0: by the time ROWS pulses have
//      happened, PE[r][c].wt_reg holds whichever row-vector was
//      presented ROWS-1-r pulses ago.
//
//   2. Activation injection: without row skew, a row-r activation pulse
//      injected simultaneously with every other row arrives at PE[r][c]
//      in lock-step with every other row's pulse, but the partial sum
//      arriving vertically from PE[r-1][c] is ALWAYS exactly one cycle
//      stale relative to that -- so un-skewed injection silently
//      computes the wrong sum (confirmed by direct simulation: it does
//      NOT just look odd, it produces numerically wrong output). Row r's
//      pulse must be injected exactly r cycles after row 0's, so that a
//      partial sum becomes available at PE[r][c] on the SAME cycle that
//      PE[r][c]'s own row's product does.
//
// Both of the above were checked against a hand-computed 3x3 example
// (W=[[1,2,3],[4,5,6],[7,8,9]], A=[1,2,3], expected column sums
// [30,36,42]) by direct simulation before this testbench was written --
// not assumed from the RTL reading alone.
//
// A further, non-obvious consequence found during that same check: once
// injected, each PE keeps RECOMPUTING (not merely relaying) psum_in+prod
// every single cycle forever, so a column's correct sum is only valid
// for the exact ONE cycle its valid_sum_out pulses -- one cycle later it
// silently reverts toward a stale partial value as the upstream relay's
// own single-cycle correctness window passes. This doesn't affect THIS
// testbench (it doesn't need to read out a "final" psum_out value, only
// to stimulate realistic switching and capture a window wide enough to
// cover it), but it is the reason the capture window below is sized to
// run well past every column's valid pulse, not stop at the last one.
//=====================================================================
`timescale 1ns/1ps
module tb_qif_systolic;

    localparam N     = 8;
    localparam ACCW  = 32;
    localparam ROWS  = 5;
    localparam COLS  = 5;
    localparam CLK_NS = 2.0;

    // Total Monte Carlo trace count. Overridable with +TOTAL=; defaults to
    // 100,000. Measured directly on 2,000 traces of this same testbench
    // (49.3s, 112.8MB plain VCD) and extrapolated linearly: ~100,000
    // traces costs roughly 41 minutes and ~5.6GB of VCD -- confirmed by
    // an actual full run, see the delivery notes for this file, not just
    // this extrapolation. Use +RESUME=/+LIMIT= (already supported by
    // qif_schedule.vh) to run this in checkpointable chunks if needed.
    integer TOTAL_TRACES;

    reg clk = 0;
    always #(CLK_NS/2) clk = ~clk;

    reg reset_n;
    reg wt_load;
    reg [COLS*N-1:0] wt_flat;
    reg [ROWS-1:0] valid_act_in;
    reg [ROWS*N-1:0] act_flat;
    wire [COLS*ACCW-1:0] psum_out;
    wire [COLS-1:0] valid_sum_out;
    wire [ROWS*N-1:0] act_out;
    wire [ROWS-1:0] valid_act_out;

    (* dont_touch = "yes" *)
    systolic_array #(
        .N    (N),
        .ACCW (ACCW),
        .ROWS (ROWS),
        .COLS (COLS)
    ) u_dut (
        .clk           (clk),
        .reset_n       (reset_n),
        .wt_load       (wt_load),
        .wt_flat       (wt_flat),
        .valid_act_in  (valid_act_in),
        .act_flat      (act_flat),
        .psum_flat     ({(COLS*ACCW){1'b0}}),
        .psum_out      (psum_out),
        .valid_sum_out (valid_sum_out),
        .act_out       (act_out),
        .valid_act_out (valid_act_out)
    );

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer r, c, k;
    integer FLUSH;
    integer CAPTURE;

    // Per-trace secret/context/background values.
    reg signed [N-1:0] w [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0] a [0:ROWS-1];
    reg signed [N-1:0] secret_val;
    reg signed [N-1:0] context_val;

    task reset_array;
        begin
            @(negedge clk);
            reset_n = 1'b0;
            @(posedge clk);
            @(negedge clk);
            reset_n = 1'b1;
        end
    endtask

    // Reverse-row-order weight load -- VERIFIED, see header.
    task load_weights;
        begin
            for (k = ROWS - 1; k >= 0; k = k - 1) begin
                for (c = 0; c < COLS; c = c + 1)
                    wt_flat[c*N +: N] = w[k][c];
                wt_load = 1'b1;
                @(posedge clk);
            end
            @(negedge clk);
            wt_load = 1'b0;
        end
    endtask

    // Row-skewed activation injection (row r's pulse r cycles after
    // row 0's) -- VERIFIED, see header. trace_t0 is latched at the
    // FIRST row's injection edge, i.e. before any of this skewed
    // sequence's switching has happened, per Rule R4 (the weight load
    // above, and this injection's own setup, stay untriggered/outside
    // the window only up to that first edge -- the injection sequence
    // itself IS the thing being measured, same as every other block in
    // this suite captures the read/compute that acts on the secret, not
    // only the first cycle of it).
    task inject_activations_and_capture;
        begin
            // Row 0 fires first. ONLY row 0's data is on the bus here; row r's
            // data is placed on the bus at its own turn (below) and removed
            // after exactly one cycle, so every row sees a single-cycle pulse.
            @(negedge clk);
            act_flat[0*N +: N] = a[0];
            valid_act_in[0] = 1'b1;
            @(posedge clk);
            trace_t0 = $realtime;
            @(negedge clk);
            act_flat[0*N +: N] = {N{1'b0}};
            valid_act_in[0]    = 1'b0;

            for (r = 1; r < ROWS; r = r + 1) begin
                act_flat[r*N +: N] = a[r];
                valid_act_in[r] = 1'b1;
                @(posedge clk);
                @(negedge clk);
                act_flat[r*N +: N] = {N{1'b0}};
                valid_act_in[r]    = 1'b0;
            end

            repeat (CAPTURE - ROWS) @(posedge clk);
        end
    endtask

    initial begin
        if (!$value$plusargs("TOTAL=%d", TOTAL_TRACES)) TOTAL_TRACES = 100_000;

        qif_get_config("qif_systolic", 1);   // context is random, not enumerated --
                                              // see header; QIF_CTX is unused beyond
                                              // the startup log line in this mode
        qif_total = TOTAL_TRACES;

        FLUSH   = 4;
        CAPTURE = ROWS + COLS + 4;   // last valid pulse at ROWS+COLS-1, plus margin
                                     // for the post-valid "decay" switching noted
                                     // in the header to also be captured

        reset_n = 1'b0; wt_load = 1'b0; valid_act_in = {ROWS{1'b0}};
        act_flat = {(ROWS*N){1'b0}}; wt_flat = {(COLS*N){1'b0}};
        repeat (4) @(posedge clk);
        reset_array;

        qif_open_meta("systolic_array", CLK_NS, CAPTURE, qif_total);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        // Whole array: w[0][0]'s only reachable effect is through
        // PE[0][0] and column 0's PEs beneath it, but dumping the full
        // grid is still correct, not a repeat of the addrgen dump-scope
        // bug from earlier in this project -- there, the issue was a
        // signal NEVER REACHING the dumped scope at all; here every
        // register the secret can possibly influence (and everything
        // else's genuinely independent, co-located switching, which a
        // real power measurement would also see) lives inside u_dut.
        $dumpvars(0, u_dut);

        for (qif_idx = 0; qif_idx < qif_total; qif_idx = qif_idx + 1) begin
            if (qif_past_slice(qif_idx)) begin
                sca_close_meta;
                $finish;
            end
            // ---- draw a fully fresh random secret + context + background ----
            // Drawn for EVERY qif_idx, before the slice test, so the PRNG
            // advances by exactly 2 + (ROWS*COLS-1) + (ROWS-1) words per
            // index whether or not this index is in the slice. That makes
            // +RESUME=/+LIMIT= chunks true continuations of one logical
            // sequence (a chunk starting at index K sees the same values a
            // single full run would have produced at K), instead of
            // replaying the sequence from the seed at each chunk's start.
            secret_val  = rand_i8(0);
            context_val = rand_i8(0);
            w[0][0] = secret_val;
            a[0]    = context_val;
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    if (!(r == 0 && c == 0))
                        w[r][c] = rand_i8(0);
            for (r = 1; r < ROWS; r = r + 1)
                a[r] = rand_i8(0);

            if (qif_in_slice(qif_idx)) begin

                // ---- setup: outside the trigger window (Rule R4) ----
                reset_array;
                repeat (FLUSH) @(posedge clk);
                load_weights;

                // ---- capture ----
                inject_activations_and_capture;

                qif_trace_end(0, secret_val, 0, context_val);
                qif_progress(qif_idx, qif_total);
            end
        end

        sca_close_meta;
        $finish;
    end

endmodule
