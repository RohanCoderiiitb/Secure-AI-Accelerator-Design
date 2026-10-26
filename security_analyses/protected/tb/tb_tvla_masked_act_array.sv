`timescale 1ns/1ps
//=====================================================================
// tb_tvla_masked_act_array.sv -- TVLA dataset generation for the
//                                ROWSxCOLS activation-masked systolic array
//                                (protected_designs/source/systolic_array_masked_act.sv)
//
// Counterpart of tb_tvla_array_masked.sv with the roles swapped: the
// WEIGHTS are plain (public, one fixed random matrix reloaded each trace)
// and the ACTIVATIONS are the secret, split into two additive shares by
// act_masker at the array's west boundary.
//
// An exhaustive enumeration is not possible here (a STREAM_LEN x ROWS INT8
// tile has 2^(8*STREAM_LEN*ROWS) values), so the traces are a random
// sample, and the NUMBER OF TRACES IS A RUN-TIME KNOB:
//     vvp ... +NTRACES=<n>          (default 2000; forced even; <= 262144)
// split exactly 50/50 into FIXED and RANDOM, in random order.
//
// Per trace
//   FIXED  group : activation tile = fix_tile (one tile for the whole run)
//   RANDOM group : fresh random tile
//   (the random tile is drawn for BOTH groups, rule R5)
// Fresh shares are drawn every cycle: the FIXED group has a fixed VALUE,
// never fixed shares.
//
// TVLA_TARGET
//   act   whole tile carries the contrast (default)
//   row0  only row 0 carries the contrast, other rows random in both groups
//         (use this for array-size sweeps; see tb_tvla_array.sv)
//   "wt"/"both" are rejected: the weights are public in this design.
//
// Plusargs: +NTRACES +SEED +MODE=tvla|null +TVLA_TARGET +TAG +OUTDIR
//           +MASK_OFF=1  m = 0 (a0 = 0, a1 = A): sanity control, TVLA MUST detect
//
// Geometry override at compile time: -Ptb_tvla_masked_act_array.ROWS=n ...COLS=n
//
// Same structural rules as the baseline array bench: skew is applied in
// the TB (not in the dumped scope), the weight-load phase is untriggered,
// masker + RNG sit outside u_dut.
//=====================================================================
module tb_tvla_masked_act_array;

    parameter N    = 8;
    parameter ACCW = 32;
    parameter ROWS = 5;
    parameter COLS = 5;

    localparam real CLK_NS = 10.0;

    localparam STREAM_LEN = 4;
    localparam CAPTURE    = STREAM_LEN + ROWS + COLS;
    localparam FLUSH      = ROWS + COLS + 2;

    reg                      clk = 1'b0;
    reg                      reset_n, wt_load;
    reg  [COLS*N-1:0]        wt_flat;
    reg  [ROWS-1:0]          valid_act_in;
    reg  [ROWS*N-1:0]        act_flat;          // plaintext, post-skew
    wire [COLS*ACCW-1:0]     ps0_o, ps1_o;
    wire [COLS-1:0]          valid_sum_out;
    wire [ROWS*ACCW-1:0]     ao0, ao1;
    wire [ROWS-1:0]          valid_act_out;

    // ================= activation masking (OUTSIDE the dumped scope) =================
    integer MASK_OFF_I;
    reg     mask_en = 1'b1;
    wire [ROWS*ACCW-1:0] mk_a0, mk_a1;
    act_masker #(.N(N), .SHARE_W(ACCW), .ROWS(ROWS), .SEED(64'd1)) u_masker (
        .clk(clk), .reset_n(reset_n), .advance(1'b1), .mask_en(mask_en),
        .act_flat(act_flat), .act0_flat(mk_a0), .act1_flat(mk_a1));

    (* dont_touch = "yes" *)
    systolic_array_masked_act #(.N(N), .SHARE_W(ACCW), .ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk(clk), .reset_n(reset_n), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act0_flat(mk_a0), .act1_flat(mk_a1),
        .psum0_flat({(COLS*ACCW){1'b0}}), .psum1_flat({(COLS*ACCW){1'b0}}),  // single tile
        .psum0_out(ps0_o), .psum1_out(ps1_o), .valid_sum_out(valid_sum_out),
        .act0_out(ao0), .act1_out(ao1), .valid_act_out(valid_act_out));

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [N-1:0] act_tile [0:STREAM_LEN-1][0:ROWS-1];
    reg signed [N-1:0] fix_tile [0:STREAM_LEN-1][0:ROWS-1];
    reg signed [N-1:0] secret_w [0:ROWS-1][0:COLS-1];   // public resident weights

    integer t, k, r, c, cyc, idx;
    reg grp, eff;
    reg signed [N-1:0] tmp8;

    // ROWS cycles of wt_load fill the columns; row ROWS-1 is driven first.
    task load_weights;
        integer rr, cc;
        begin
            for (rr = ROWS-1; rr >= 0; rr = rr - 1) begin
                @(negedge clk);
                wt_load = 1'b1;
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    tmp8 = secret_w[rr][cc];
                    wt_flat[cc*N +: N] = tmp8;
                end
                @(posedge clk);
            end
            @(negedge clk);
            wt_load = 1'b0;
            wt_flat = {(COLS*N){1'b0}};
        end
    endtask

    initial begin
        sca_get_config("masked_act_array");
        if (TVLA_TARGET != "act" && TVLA_TARGET != "row0") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- use 'act' or 'row0' (weights are public here)", TVLA_TARGET);
            $finish;
        end
        if (!$value$plusargs("MASK_OFF=%d", MASK_OFF_I)) MASK_OFF_I = 0;
        mask_en = (MASK_OFF_I == 0);
        $display("[MASK] mask_en=%0d  traces=%0d (%0d fixed + %0d random)",
                 mask_en, NTRACES, NTRACES/2, NTRACES/2);

        for (r = 0; r < ROWS; r = r + 1)
            for (c = 0; c < COLS; c = c + 1)
                secret_w[r][c] = rand_i8(0);
        for (k = 0; k < STREAM_LEN; k = k + 1)
            for (r = 0; r < ROWS; r = r + 1)
                fix_tile[k][r] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                     // SCOPE-LIMITED: bare mesh only

        sca_open_meta("systolic_array_masked_act", CLK_NS, CAPTURE);
        $display("[SCA] array geometry ROWS=%0d COLS=%0d ACCW=%0d capture=%0d cycles",
                 ROWS, COLS, ACCW, CAPTURE);

        reset_n      = 1'b0;
        wt_load      = 1'b0;
        wt_flat      = {(COLS*N){1'b0}};
        valid_act_in = {ROWS{1'b0}};
        act_flat     = {(ROWS*N){1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw the full random tile for both groups.
            for (k = 0; k < STREAM_LEN; k = k + 1)
                for (r = 0; r < ROWS; r = r + 1)
                    act_tile[k][r] = rand_i8(0);

            if (TVLA_TARGET == "row0") begin
                if (!eff)
                    for (k = 0; k < STREAM_LEN; k = k + 1)
                        act_tile[k][0] = fix_tile[k][0];
            end else if (!eff) begin
                for (k = 0; k < STREAM_LEN; k = k + 1)
                    for (r = 0; r < ROWS; r = r + 1)
                        act_tile[k][r] = fix_tile[k][r];
            end

            // ---- weight load, untriggered (R4) ----
            load_weights;

            // ---- flush, untriggered ----
            @(negedge clk);
            valid_act_in = {ROWS{1'b0}};
            act_flat     = {(ROWS*N){1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window: skewed activation wavefront ----
            for (cyc = 0; cyc < CAPTURE; cyc = cyc + 1) begin
                @(negedge clk);
                for (r = 0; r < ROWS; r = r + 1) begin
                    idx = cyc - r;                   // row r is delayed r cycles
                    if (idx >= 0 && idx < STREAM_LEN) begin
                        act_flat[r*N +: N] = act_tile[idx][r];
                        valid_act_in[r]    = 1'b1;
                    end else begin
                        act_flat[r*N +: N] = {N{1'b0}};
                        valid_act_in[r]    = 1'b0;
                    end
                end
                @(posedge clk);
                if (cyc == 0) sca_trace_begin;
            end

            @(negedge clk);
            valid_act_in = {ROWS{1'b0}};
            act_flat     = {(ROWS*N){1'b0}};
            sca_trace_end(grp);

            if (t % 200 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end
endmodule
