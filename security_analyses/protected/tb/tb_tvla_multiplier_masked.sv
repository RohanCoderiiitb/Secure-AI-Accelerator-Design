`timescale 1ns/1ps
//=====================================================================
// tb_tvla_mult_masked.sv -- TVLA dataset generation for
//                           masked_weight_multiplier (multiplier_wt_masked.sv)
//
// Masked counterpart of tb_tvla_mult.v. Same trace structure, same
// scope-limited dump, same PRNG discipline, so run_tvla.py / run_adla.py /
// vcd_power.py work unchanged on its output.
//
// WHAT IS THE SECRET.  The WEIGHT. It is held as two arithmetic shares
//   w0 + w1 = sext(W) (mod 2^SW), written once per trace through w_load
// with a FRESH mask each trace (w0 = r, w1 = sext(W) - r). The activation
// `a` is public and is driven through a one-stage input register, exactly
// the envelope the multiplier sees inside a PE; the two share products are
// latched into p0_out / p1_out (stand-ins for the PE's psum registers).
//
// TRACE STRUCTURE (identical to tb_tvla_mult):
//   [w_load, 1 cycle]  -- untriggered, outside the window (rule R4)
//   FLUSH quiet cycles -- zero operand, untriggered
//   OPS   operand cycles inside the window  (+1 drain cycle)
//
// GROUPS (TVLA_TARGET, default in sca_capture.vh is "act" -- pass wt!):
//   wt   fixed group : weight = FIXW (one value, all traces)
//        random group: weight = fresh random INT8 per trace
//        activation sequence is the SAME fixed sequence in both groups
//   act  weight = FIXW in both groups, activation fixed vs random
//        (activations are PUBLIC: this is expected to leak; it is a
//         sanity check that the bench can see leakage, not a defect)
//   both weight and activation fixed vs random
//   sh0  SHARE-0 test of the refresh: the weight is RANDOM in both groups,
//        but share 0 of the loaded pair is FIXED (one 32-bit word) vs random.
//        This asks "does the window still depend on the value the share
//        had when it was loaded?". With +REFRESH=0 it should (a share held
//        constant can be attacked on its own -- the CPA scenario the design
//        comment describes: EXPECTED leak, evidence that refresh is needed).
//        With +REFRESH=1 the refresh has re-randomised both shares before
//        the window, so it should NOT. (+MASK_EN is ignored for sh0.)
//
// MASKS AND REFRESH
//   +MASK_EN=1 (default) fresh mask per load, fresh refresh word per cycle
//   +MASK_EN=0 POSITIVE CONTROL: w0 = 0, w1 = W, refresh word = 0. The same
//              hardware must leak again, otherwise this bench is blind.
//   +REFRESH=1 (default) refresh_en = 1 in every flush/window/drain cycle
//              with a fresh r_refresh each cycle (the intended operating
//              mode of the design: shares never stay constant)
//   +REFRESH=0 shares static for the whole trace (isolates what refresh buys)
//   +FLUSH=<n> quiet cycles between w_load and the window (default 3). With
//              refresh on, FLUSH=0 starts compute BEFORE any refresh has run,
//              so the first window cycle(s) still see the load-time shares.
//   +FIXW=<int> override the fixed weight (repeat with several values:
//              a single fixed value is a known TVLA caveat)
//
// NULL RUN (+MODE=null): fixed-vs-fixed, labels still random (rule R6).
// Because masks are fresh per trace this null has REAL across-trace
// variance (the unmasked null is identically zero), so its |t| statistics
// are a genuine test of the t-test, not a vacuous pass.
//
// PRNG DISCIPLINE (rule R5): every random value is drawn for EVERY trace
// and cycle regardless of group, so the random stream never depends on the
// label. Stimulus registers, schedule and PRNG are outside the dumped scope.
//
// Compile (include dir must hold sca_capture.vh):
//   iverilog -g2012 -I ../scripts -o tvla_mm.vvp tb_tvla_mult_masked.sv multiplier_wt_masked.sv
// Run:
//   vvp tvla_mm.vvp +NTRACES=2000 +MODE=null +TVLA_TARGET=wt +TAG=mm_null +OUTDIR=traces
//   vvp tvla_mm.vvp +NTRACES=2000 +MODE=tvla +TVLA_TARGET=wt +TAG=mm_wt   +OUTDIR=traces
//   vvp tvla_mm.vvp +NTRACES=2000 +MODE=tvla +TVLA_TARGET=wt +MASK_EN=0 +TAG=mm_wt_ctl +OUTDIR=traces
//=====================================================================

// Registered envelope. Only THIS scope is dumped.
module masked_mult_dut #(
    parameter N  = 8,
    parameter SW = 32
)(
    input  wire          clk,
    input  wire          reset_n,
    input  wire          en,
    input  wire          w_load,
    input  wire [SW-1:0] w0_in,
    input  wire [SW-1:0] w1_in,
    input  wire          refresh_en,
    input  wire [SW-1:0] r_refresh,
    input  wire [N-1:0]  a_in,
    output reg  [SW-1:0] p0_out,
    output reg  [SW-1:0] p1_out
);
    reg  [N-1:0]  a_r;
    wire [SW-1:0] p0, p1;

    (* dont_touch = "yes" *)
    masked_weight_multiplier #(.N(N), .SW(SW)) u_mwm (
        .clk(clk), .reset_n(reset_n), .w_load(w_load),
        .w0_in(w0_in), .w1_in(w1_in),
        .refresh_en(refresh_en), .r_refresh(r_refresh),
        .a(a_r), .p0(p0), .p1(p1)
    );

    always @(posedge clk) begin
        if (!reset_n) begin
            a_r    <= {N{1'b0}};
            p0_out <= {SW{1'b0}};
            p1_out <= {SW{1'b0}};
        end else if (en) begin
            a_r    <= a_in;
            p0_out <= p0;           // share products of the PREVIOUS operand
            p1_out <= p1;
        end
    end
endmodule


module tb_tvla_mult_masked;

    localparam N       = 8;
    localparam SW      = 32;
    localparam real CLK_NS = 10.0;

    localparam OPS     = 4;
    integer FLUSH = 3;               // quiet cycles between load and window (+FLUSH=<n>)
    localparam CAPTURE = OPS + 1;

    reg                  clk = 1'b0;
    reg                  reset_n, en, w_load, refresh_en;
    reg  [SW-1:0]        w0_in, w1_in, r_refresh;
    reg  [N-1:0]         a_in;
    wire [SW-1:0]        p0_out, p1_out;

    masked_mult_dut #(.N(N), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en),
        .w_load(w_load), .w0_in(w0_in), .w1_in(w1_in),
        .refresh_en(refresh_en), .r_refresh(r_refresh),
        .a_in(a_in), .p0_out(p0_out), .p1_out(p1_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    // fixed-population values, drawn once from the seeded PRNG
    reg signed [N-1:0] fix_act [0:OPS-1];
    reg signed [N-1:0] fixW;
    reg [SW-1:0]       fixw0;           // fixed share-0 word for the sh0 target

    integer t, k, MASK_EN_I, REFRESH_I, FIXW_I;
    reg grp, eff;
    reg signed [N-1:0] rw, ra, W, act;
    reg [SW-1:0] rmask, rref, w0, w1;

    // refresh word for this cycle (always drawn, R5)
    task set_refresh;
        begin
            rref      = rand_word(SW);
            r_refresh = (MASK_EN_I != 0) ? rref : {SW{1'b0}};
            refresh_en = (REFRESH_I != 0);
        end
    endtask

    initial begin
        sca_get_config("mult_masked");
        if (!$value$plusargs("MASK_EN=%d", MASK_EN_I)) MASK_EN_I = 1;
        if (!$value$plusargs("REFRESH=%d", REFRESH_I)) REFRESH_I = 1;
        if (!$value$plusargs("FLUSH=%d",   FLUSH))     FLUSH     = 3;

        for (k = 0; k < OPS; k = k + 1) fix_act[k] = rand_i8(0);
        fixW = rand_i8(0);
        fixw0 = rand_word(SW);
        if ($value$plusargs("FIXW=%d", FIXW_I)) fixW = FIXW_I;

        $display("[MASK] mask_en=%0d refresh=%0d fixed weight=%0d target=%0s mode=%0s",
                 MASK_EN_I, REFRESH_I, fixW, TVLA_TARGET, MODE);
        if (TVLA_TARGET == "act")
            $display("[MASK] NOTE: target=act varies the PUBLIC activation; leakage is EXPECTED. Use +TVLA_TARGET=wt for the weight.");

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: masked envelope only

        sca_open_meta("masked_mult_dut", CLK_NS, CAPTURE);

        reset_n = 1'b0; en = 1'b0; w_load = 1'b0; refresh_en = 1'b0;
        w0_in = {SW{1'b0}}; w1_in = {SW{1'b0}}; r_refresh = {SW{1'b0}}; a_in = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- per-trace draws (always, R5) ----
            rw    = rand_i8(0);
            rmask = rand_word(SW);

            // weight for this trace
            if (TVLA_TARGET == "act")      W = fixW;
            else if (TVLA_TARGET == "sh0") W = rw;            // weight random in BOTH groups
            else                           W = eff ? rw : fixW;
            if (TVLA_TARGET == "sh0")      w0 = eff ? rmask : fixw0;   // share 0: random vs fixed word
            else                           w0 = (MASK_EN_I != 0) ? rmask : {SW{1'b0}};
            w1 = {{(SW-N){W[N-1]}}, W} - w0;

            // ---- weight-share load: outside the window (R4) ----
            @(negedge clk);
            refresh_en = 1'b0; r_refresh = {SW{1'b0}};
            en = 1'b1; a_in = {N{1'b0}};
            w_load = 1'b1; w0_in = w0; w1_in = w1;
            @(posedge clk);
            @(negedge clk);
            w_load = 1'b0;

            // ---- flush (untriggered): zero operand, refresh already running ----
            set_refresh;
            repeat (FLUSH) begin
                @(posedge clk);
                @(negedge clk);
                set_refresh;
            end

            // ---- capture window ----
            for (k = 0; k < OPS; k = k + 1) begin
                ra = rand_i8(0);                       // R5: always draw
                if (TVLA_TARGET == "wt" || TVLA_TARGET == "sh0") act = fix_act[k];   // act held
                else                     act = eff ? ra : fix_act[k]; // act / both
                a_in = act;
                @(posedge clk);
                if (k == 0) sca_trace_begin;
                @(negedge clk);
                set_refresh;
            end

            // ---- drain ----
            a_in = {N{1'b0}};
            @(posedge clk);
            sca_trace_end(grp);
            @(negedge clk);
            refresh_en = 1'b0;

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        en = 1'b0; refresh_en = 1'b0;
        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule