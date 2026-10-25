`timescale 1ns/1ps
//=====================================================================
// tb_tvla_masked_mult.sv -- TVLA dataset generation for the
//                           weight-masked multiplier
//                           (protected_designs/source/masked_multiplier.sv)
//
// Secret under test: the WEIGHT. One multiplication per trace.
//
// Exhaustive coverage (default N = 131072 = 2 x 65536):
//   RANDOM group : every (weight, activation) pair, all 256 x 256 = 65536
//                  of them, each exactly once, in a shuffled order
//   FIXED  group : the fixed weight (+FIXED_W) with every activation,
//                  each of the 256 activations exactly 256 times, shuffled
// Both groups therefore see the SAME activation distribution; the only
// difference between them is the weight, which is what makes this a
// weight test. With N < 131072 each group gets a prefix of its shuffled
// list (a uniform random subset). With N > 131072 the lists wrap.
//
// Masking (done here, outside the dumped scope):
//   m random 16-bit, w0 = sext(w) - m, w1 = m        -- every trace
//   r random 16-bit refresh value                    -- every cycle
// The FIXED group uses a fixed weight VALUE with fresh shares every
// trace, never fixed shares.
//
// Rules from sca_capture.vh still apply:
//   R1 one continuous simulation       R2 random group order
//   R3 labels only in the sidecar      R4 setup outside the window
//   R5 identical PRNG draws for both groups (masks and refresh are drawn
//      every trace/cycle whatever the group; the pair lists are built
//      before the run)
//   R6 +MODE=null gives fixed-vs-fixed
//
// Extra plusargs
//   +FIXED_W=<int>   fixed weight, signed decimal (default -77)
//   +MASK_OFF=1      masking off (m = 0, r = 0): sanity control. TVLA
//                    MUST detect leakage in this mode; if it does not,
//                    the setup cannot see weight leakage at all.
//
// Per-trace timing (clock period 10 ns, stimulus on the negedge):
//   flush   2 cycles  zero activation, fresh shares of weight 0 (untriggered)
//   cyc 0   posedge loads activation and weight shares; multiplier evaluates
//   cyc 1   p0/p1 registered; shares refreshed, multiplier re-evaluates
//   cyc 2   p0/p1 registered again with the refreshed shares
//=====================================================================

module masked_mult_dut #(
    parameter N  = 8,
    parameter SW = 2*N
)(
    input  wire          clk,
    input  wire          reset_n,
    input  wire          en,
    input  wire [N-1:0]  x_in,        // activation (public)
    input  wire          w_load,
    input  wire [SW-1:0] w0_in,
    input  wire [SW-1:0] w1_in,
    input  wire [SW-1:0] r_refresh,
    output reg  [SW-1:0] p0_out,
    output reg  [SW-1:0] p1_out
);
    reg  [N-1:0]  x_r;
    wire [SW-1:0] p0, p1;

    (* dont_touch = "yes" *)
    masked_weight_multiplier #(.N(N), .SW(SW)) u_mmul (
        .clk       (clk),
        .reset_n   (reset_n),
        .w_load    (w_load),
        .w0_in     (w0_in),
        .w1_in     (w1_in),
        .refresh_en(en & ~w_load),
        .r_refresh (r_refresh),
        .a         (x_r),
        .p0        (p0),
        .p1        (p1)
    );

    // product shares stay separate; they are never added in this scope
    always @(posedge clk) begin
        if (!reset_n) begin
            x_r    <= {N{1'b0}};
            p0_out <= {SW{1'b0}};
            p1_out <= {SW{1'b0}};
        end else if (en) begin
            x_r    <= x_in;
            p0_out <= p0;
            p1_out <= p1;
        end
    end
endmodule


module tb_tvla_masked_mult;

    localparam N       = 8;
    localparam SW      = 2*N;
    localparam real CLK_NS = 10.0;
    localparam FLUSH   = 2;
    localparam CAPTURE = 3;
    localparam NPAIRS  = 65536;

    reg           clk = 1'b0;
    reg           reset_n, en, w_load;
    reg  [N-1:0]  x_in;
    reg  [SW-1:0] w0_in, w1_in, r_refresh;
    wire [SW-1:0] p0_out, p1_out;

    masked_mult_dut #(.N(N), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en),
        .x_in(x_in), .w_load(w_load), .w0_in(w0_in), .w1_in(w1_in),
        .r_refresh(r_refresh), .p0_out(p0_out), .p1_out(p1_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    // shuffled pair lists, built once before the run
    reg [15:0] list_r [0:NPAIRS-1];   // random group: {w, a}, all 65536 pairs
    reg [15:0] list_f [0:NPAIRS-1];   // fixed group:  {-, a}, each a 256 times

    integer t, i, j, idx_r, idx_f, mask_off, fixed_w_int;
    integer n_cov_r, n_cov_f;
    reg     grp, eff;
    reg [15:0] tmp, pair;
    reg [N-1:0]  a_val, w_val, fixed_w;
    reg [63:0]   rw;
    reg [SW-1:0] w_ext, m;

    // weight -> two arithmetic shares; always draws one PRNG word (R5)
    task share_weight(input [N-1:0] w);
        begin
            rw    = rand_word(SW);
            m     = mask_off ? {SW{1'b0}} : rw[SW-1:0];
            w_ext = {{(SW-N){w[N-1]}}, w};
            w0_in = w_ext - m;
            w1_in = m;
        end
    endtask

    // fresh refresh value; always draws one PRNG word (R5)
    task draw_refresh;
        begin
            rw        = rand_word(SW);
            r_refresh = mask_off ? {SW{1'b0}} : rw[SW-1:0];
        end
    endtask

    task shuffle_lists;
        begin
            for (i = 0; i < NPAIRS; i = i + 1) begin
                list_r[i] = i[15:0];                 // {w, a}
                list_f[i] = i[15:0];                 // low byte = a, 256 times each
            end
            for (i = NPAIRS - 1; i > 0; i = i - 1) begin
                j = xs64s(0) % (i + 1);
                tmp = list_r[i]; list_r[i] = list_r[j]; list_r[j] = tmp;
                j = xs64s(0) % (i + 1);
                tmp = list_f[i]; list_f[i] = list_f[j]; list_f[j] = tmp;
            end
        end
    endtask

    initial begin
        sca_get_config("masked_mult");
        if (!$value$plusargs("MASK_OFF=%d", mask_off))    mask_off    = 0;
        if (!$value$plusargs("FIXED_W=%d",  fixed_w_int)) fixed_w_int = -77;
        fixed_w = fixed_w_int[N-1:0];

        shuffle_lists;
        idx_r = 0; idx_f = 0;
        $display("[SCA] masked multiplier: fixed_w=%0d mask_off=%0d, %0s",
                 $signed(fixed_w), mask_off,
                 (NTRACES >= 2*NPAIRS) ? "EXHAUSTIVE (all w x a pairs)"
                                       : "subset of the pair lists");

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: DUT only

        sca_open_meta("masked_mult_dut", CLK_NS, CAPTURE);

        // reset and settle, never inside a window
        reset_n = 1'b0; en = 1'b0; w_load = 1'b0;
        x_in = 0; w0_in = 0; w1_in = 0; r_refresh = 0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1; en = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // pick the pair for this trace
            if (eff) begin
                pair  = list_r[idx_r % NPAIRS];
                w_val = pair[15:8];
                a_val = pair[7:0];
            end else begin
                pair  = list_f[idx_f % NPAIRS];
                w_val = fixed_w;
                a_val = pair[7:0];
            end
            // each LABEL walks its own list, so in null mode both labels
            // still cover every activation equally
            if (grp) idx_r = idx_r + 1; else idx_f = idx_f + 1;

            // ---- flush (untriggered): zero activation, shares of weight 0 ----
            @(negedge clk);
            x_in = 0; share_weight(0); w_load = 1'b1; draw_refresh;
            @(posedge clk);
            repeat (FLUSH-1) begin
                @(negedge clk);
                w_load = 1'b0; draw_refresh;
                @(posedge clk);
            end

            // ---- capture cycle 0: load activation and weight shares ----
            @(negedge clk);
            x_in = a_val; share_weight(w_val); w_load = 1'b1; draw_refresh;
            @(posedge clk);
            sca_trace_begin;

            // ---- capture cycle 1: product registered, shares refreshed ----
            @(negedge clk);
            w_load = 1'b0; draw_refresh;            // x_in held
            @(posedge clk);

            // ---- capture cycle 2: product registered again ----
            @(negedge clk);
            draw_refresh;
            @(posedge clk);
            sca_trace_end(grp);

            if (t % 10000 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        n_cov_r = (idx_r < NPAIRS) ? idx_r : NPAIRS;
        n_cov_f = (idx_f < NPAIRS) ? idx_f : NPAIRS;
        $display("[SCA] coverage: random-label list %0d / %0d pairs, fixed-label list %0d / %0d",
                 n_cov_r, NPAIRS, n_cov_f, NPAIRS);

        @(negedge clk);
        x_in = 0; w_load = 1'b0; en = 1'b0;
        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
