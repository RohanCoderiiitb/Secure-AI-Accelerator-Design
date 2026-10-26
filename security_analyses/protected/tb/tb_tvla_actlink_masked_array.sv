`timescale 1ns/1ps
//=====================================================================
// tb_tvla_actlink_masked_array.sv -- TVLA dataset generation for the
//                                ROWSxCOLS array with UNMASKED PE multipliers and
//                                activation masking on the east-flowing links
//                                (protected_designs/source/systolic_array_actlink_masked.sv)
//
// PEs are the UNMODIFIED baseline processing_element (plain multiplier).
// Masking lives in the array only: act_masker at the west boundary and
// act_link_masked stages between PEs. To keep the masker out of the dumped
// scope (R4), the PE and link instances are dumped individually, not u_dut.
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
// Geometry override at compile time: -Ptb_tvla_actlink_masked_array.ROWS=n ...COLS=n
//
// Same structural rules as the baseline array bench: skew is applied in
// the TB (not in the dumped scope), the weight-load phase is untriggered,
// masker + RNG are not in the dumped scope.
//=====================================================================
module tb_tvla_actlink_masked_array;

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
    wire [COLS*ACCW-1:0]     ps_o;
    wire [COLS-1:0]          valid_sum_out;
    wire [ROWS*N-1:0]        ao;
    wire [ROWS-1:0]          valid_act_out;

    integer MASK_OFF_I;
    reg     mask_en = 1'b1;

    systolic_array_actlink_masked #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS),
                                    .MASK_SEED(64'd1)) u_dut (
        .clk(clk), .reset_n(reset_n), .mask_en(mask_en), .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat),
        .psum_flat({(COLS*ACCW){1'b0}}),                      // single tile
        .psum_out(ps_o), .valid_sum_out(valid_sum_out),
        .act_out(ao), .valid_act_out(valid_act_out));

    // dump the PEs and the array's activation-link stages; masker/RNG stay outside
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_dump_r
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_dump_c
                initial begin
                    #1;                                       // after $dumpfile at t=0
                    $dumpvars(0, u_dut.g_row[gr].g_col[gc].pe_inst);
                end
            end
            for (gc = 0; gc <= COLS; gc = gc + 1) begin : g_dump_l
                initial begin
                    #1;
                    if (gc == 0) $dumpvars(0, u_dut.g_row[gr].g_lnk[0].g_first.u_link);
                    else         $dumpvars(0, u_dut.g_row[gr].g_lnk[gc].g_next.u_link);
                end
            end
        end
    endgenerate

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
        sca_get_config("actlink_masked_array");
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
        // $dumpvars: per-PE / per-link generate blocks above (masker excluded)

        sca_open_meta("systolic_array_actlink_masked", CLK_NS, CAPTURE);
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
