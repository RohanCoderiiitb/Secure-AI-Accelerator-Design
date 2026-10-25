`timescale 1ns/1ps
//=====================================================================
// tvla_tb_masked_act_multiplier.sv -- TVLA dataset generation for the
//                               activation-masked multiplier
//                               (protected_designs/source/masked_act_multiplier.sv)
//
// Secret under test: the ACTIVATION. Weight is plain (public).
//
// Exhaustive coverage (default N = 131072 = 2 x 65536):
//   RANDOM group : every (weight, activation) pair once, shuffled
//   FIXED  group : the fixed activation (+FIXED_A) with every weight,
//                  each weight 256 times, shuffled
// Both groups see the same weight distribution; only the activation differs.
//
// Masking (done here, outside the dumped scope):
//   m random 16-bit, a0 = sext(a) - m, a1 = m   -- EVERY cycle
//   (the same activation is re-masked in every capture cycle)
// The FIXED group uses a fixed VALUE with fresh shares, never fixed shares.
//
// Rules from sca_capture.vh still apply (R1..R6). R5: one PRNG word is
// drawn every cycle whatever the group.
//
// Extra plusargs
//   +FIXED_A=<int>  fixed activation, signed decimal (default 93)
//   +MASK_OFF=1     m = 0: sanity control, TVLA MUST detect
//
// Per-trace timing (clock 10 ns, stimulus on the negedge):
//   flush   2 cycles  shares of activation 0, weight 0 (untriggered)
//   cyc 0   posedge loads activation shares and weight; products evaluate
//   cyc 1   p0/p1 registered; activation re-masked, products re-evaluate
//   cyc 2   p0/p1 registered again
//=====================================================================

module masked_act_mult_dut #(
    parameter N  = 8,
    parameter SW = 2*N
)(
    input  wire          clk,
    input  wire          reset_n,
    input  wire          en,
    input  wire [SW-1:0] a0_in,
    input  wire [SW-1:0] a1_in,
    input  wire          w_load,
    input  wire [N-1:0]  w_in,
    output reg  [SW-1:0] p0_out,
    output reg  [SW-1:0] p1_out
);
    reg  [SW-1:0] a0_r, a1_r;      // activation share registers
    wire [SW-1:0] p0, p1;

    (* dont_touch = "yes" *)
    masked_act_multiplier #(.N(N), .SW(SW)) u_mmul (
        .clk    (clk),
        .reset_n(reset_n),
        .w_load (w_load),
        .w_in   (w_in),
        .a0     (a0_r),
        .a1     (a1_r),
        .p0     (p0),
        .p1     (p1)
    );

    // shares stay separate; they are never added in this scope
    always @(posedge clk) begin
        if (!reset_n) begin
            a0_r   <= {SW{1'b0}};
            a1_r   <= {SW{1'b0}};
            p0_out <= {SW{1'b0}};
            p1_out <= {SW{1'b0}};
        end else if (en) begin
            a0_r   <= a0_in;
            a1_r   <= a1_in;
            p0_out <= p0;
            p1_out <= p1;
        end
    end
endmodule


module tb_tvla_masked_act_mult;

    localparam N       = 8;
    localparam SW      = 2*N;
    localparam real CLK_NS = 10.0;
    localparam FLUSH   = 2;
    localparam CAPTURE = 3;
    localparam NPAIRS  = 65536;

    reg           clk = 1'b0;
    reg           reset_n, en, w_load;
    reg  [SW-1:0] a0_in, a1_in;
    reg  [N-1:0]  w_in;
    wire [SW-1:0] p0_out, p1_out;

    masked_act_mult_dut #(.N(N), .SW(SW)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en),
        .a0_in(a0_in), .a1_in(a1_in), .w_load(w_load), .w_in(w_in),
        .p0_out(p0_out), .p1_out(p1_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg [15:0] list_r [0:NPAIRS-1];   // random group: {w, a}, all 65536 pairs
    reg [15:0] list_f [0:NPAIRS-1];   // fixed group: low byte = weight, 256 times each

    integer t, i, j, idx_r, idx_f, mask_off, fixed_a_int;
    integer n_cov_r, n_cov_f;
    reg     grp, eff;
    reg [15:0]   tmp, pair;
    reg [N-1:0]  a_val, w_val, fixed_a;
    reg [63:0]   rw;
    reg [SW-1:0] m;

    // activation -> two shares; always one PRNG word (R5)
    task share_act(input [N-1:0] a);
        begin
            rw    = rand_word(SW);
            m     = mask_off ? {SW{1'b0}} : rw[SW-1:0];
            a0_in = {{(SW-N){a[N-1]}}, a} - m;
            a1_in = m;
        end
    endtask

    task shuffle_lists;
        begin
            for (i = 0; i < NPAIRS; i = i + 1) begin
                list_r[i] = i[15:0];
                list_f[i] = i[15:0];
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
        sca_get_config("masked_act_mult");
        if (!$value$plusargs("MASK_OFF=%d", mask_off))    mask_off    = 0;
        if (!$value$plusargs("FIXED_A=%d",  fixed_a_int)) fixed_a_int = 93;
        fixed_a = fixed_a_int[N-1:0];

        shuffle_lists;
        idx_r = 0; idx_f = 0;
        $display("[SCA] activation-masked multiplier: fixed_a=%0d mask_off=%0d, %0s",
                 $signed(fixed_a), mask_off,
                 (NTRACES >= 2*NPAIRS) ? "EXHAUSTIVE (all w x a pairs)"
                                       : "subset of the pair lists");

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                 // SCOPE-LIMITED: DUT only

        sca_open_meta("masked_act_mult_dut", CLK_NS, CAPTURE);

        reset_n = 1'b0; en = 1'b0; w_load = 1'b0;
        a0_in = 0; a1_in = 0; w_in = 0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1; en = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            if (eff) begin
                pair  = list_r[idx_r % NPAIRS];
                w_val = pair[15:8];
                a_val = pair[7:0];
            end else begin
                pair  = list_f[idx_f % NPAIRS];
                w_val = pair[7:0];
                a_val = fixed_a;
            end
            if (grp) idx_r = idx_r + 1; else idx_f = idx_f + 1;

            // ---- flush (untriggered): shares of activation 0, weight 0 ----
            @(negedge clk);
            share_act(0); w_in = 0; w_load = 1'b1;
            @(posedge clk);
            repeat (FLUSH-1) begin
                @(negedge clk);
                share_act(0); w_load = 1'b0;
                @(posedge clk);
            end

            // ---- capture cycle 0: load activation shares and weight ----
            @(negedge clk);
            share_act(a_val); w_in = w_val; w_load = 1'b1;
            @(posedge clk);
            sca_trace_begin;

            // ---- capture cycle 1: products registered, activation re-masked ----
            @(negedge clk);
            share_act(a_val); w_load = 1'b0;
            @(posedge clk);

            // ---- capture cycle 2: products registered again ----
            @(negedge clk);
            share_act(a_val);
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
        a0_in = 0; a1_in = 0; w_load = 1'b0; en = 1'b0;
        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
