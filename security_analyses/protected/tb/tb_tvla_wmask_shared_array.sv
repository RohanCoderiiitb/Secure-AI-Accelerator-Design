`timescale 1ns/1ps
//=====================================================================
// tb_tvla_wmask_shared_array.sv -- TVLA dataset generation for
//                                  systolic_array_wmask_shared
//
// Secret = WEIGHTS (model IP). Activations are public and random in both
// groups. Same structure and rules as tb_tvla_actlink_masked_array.sv:
//   * weight load and mask refresh are untriggered (R4)
//   * skew/de-skew applied in the TB, outside the DUT
//   * mask generator (u_mgen) and north-edge masking (g_entry) are NOT
//     dumped: they see the plain weight only during the load phase
//   * the random weight matrix is drawn for BOTH groups (R5)
//   * FIXED group = fixed weight VALUES, fresh masks every trace
//
// Per trace:  mask_refresh (ROWS cyc) -> wt_load (ROWS cyc) -> flush ->
//             capture window (skewed random activation tile)
//
// TVLA_TARGET
//   wt    whole weight matrix carries the contrast (default for this bench)
//   row0  only row 0 weights carry the contrast; other rows random in both
//   "act" is rejected (activations are public in this threat model)
//
// Plusargs: +NTRACES +SEED +MODE=tvla|null +TVLA_TARGET +TAG +OUTDIR
//           +MASK_OFF=1   R = 0 (unmasked): positive control, TVLA MUST detect
//           +FIXSEED=<n>  seed for the FIXED weight matrix only (multi-seed runs)
//           +DUMP_SHADOW=1  also dump the shadow column (should be clean)
//           +DUMP_OUT=1     also dump the per-column recombination (g_out)
//
// Compile:
//   iverilog -g2012 -I <dir of sca_capture.vh> -o tvla.vvp \
//     multiplier.sv systolic_array_wmask_shared.sv tb_tvla_wmask_shared_array.sv
// Geometry: -Ptb_tvla_wmask_shared_array.ROWS=n -Ptb_tvla_wmask_shared_array.COLS=n
//=====================================================================
module tb_tvla_wmask_shared_array;

    parameter N    = 8;
    parameter ACCW = 32;
    parameter ROWS = 5;
    parameter COLS = 5;

    localparam real CLK_NS = 10.0;

    localparam STREAM_LEN = 4;
    localparam CAPTURE    = STREAM_LEN + ROWS + COLS;
    localparam FLUSH      = ROWS + COLS + 2;

    reg                      clk = 1'b0;
    reg                      reset_n, wt_load, mask_refresh;
    reg  [COLS*N-1:0]        wt_flat;
    reg  [ROWS-1:0]          valid_act_in;
    reg  [ROWS*N-1:0]        act_flat;
    wire [COLS*ACCW-1:0]     ps_o;
    wire [COLS-1:0]          valid_sum_out;
    wire [ROWS*N-1:0]        ao;
    wire [ROWS-1:0]          valid_act_out;

    integer MASK_OFF_I, FIXSEED_I, DUMP_SHADOW_I, DUMP_OUT_I;
    integer fixseed_state;
    reg     use_fixseed;
    reg     mask_en = 1'b1;

    systolic_array_wmask_shared #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk(clk), .reset_n(reset_n), .mask_en(mask_en), .mask_refresh(mask_refresh),
        .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat),
        .psum_flat({(COLS*ACCW){1'b0}}),                       // single tile
        .psum_out(ps_o), .valid_sum_out(valid_sum_out),
        .act_out(ao), .valid_act_out(valid_act_out));

    // ---- dump scope: PEs always; shadow / recombination on request ----
    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr = gr + 1) begin : g_dump_r
            for (gc = 0; gc < COLS; gc = gc + 1) begin : g_dump_c
                initial begin
                    #1;                                   // after $dumpfile at t=0
                    $dumpvars(0, u_dut.g_row[gr].g_col[gc].pe_inst);
                end
            end
            initial begin
                #1;
                if (DUMP_SHADOW_I != 0) $dumpvars(0, u_dut.g_shadow[gr].sh_inst);
            end
        end
        for (gc = 0; gc < COLS; gc = gc + 1) begin : g_dump_o
            initial begin
                #1;
                if (DUMP_OUT_I != 0) $dumpvars(0, u_dut.g_out[gc].y);
            end
        end
    endgenerate

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [N-1:0] act_tile [0:STREAM_LEN-1][0:ROWS-1];
    reg signed [N-1:0] cur_w    [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0] fix_w    [0:ROWS-1][0:COLS-1];

    integer t, k, r, c, cyc, idx;
    reg grp, eff;
    reg signed [N-1:0] tmp8;

    task refresh_masks;          // untriggered, fresh R_r for every trace
        begin
            @(negedge clk); mask_refresh = 1'b1;
            repeat (ROWS) @(posedge clk);
            @(negedge clk); mask_refresh = 1'b0;
        end
    endtask

    task load_weights;           // untriggered; row ROWS-1 driven first
        integer rr, cc;
        begin
            for (rr = ROWS-1; rr >= 0; rr = rr - 1) begin
                @(negedge clk);
                wt_load = 1'b1;
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    tmp8 = cur_w[rr][cc];
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
        if (!$value$plusargs("DUMP_SHADOW=%d", DUMP_SHADOW_I)) DUMP_SHADOW_I = 0;
        if (!$value$plusargs("DUMP_OUT=%d",    DUMP_OUT_I))    DUMP_OUT_I    = 0;
    end

    initial begin
        sca_get_config("wmask_shared_array");
        if (TVLA_TARGET != "wt" && TVLA_TARGET != "row0") begin
            $display("[SCA] FATAL: TVLA_TARGET=%0s -- use 'wt' or 'row0' (activations are public here)", TVLA_TARGET);
            $finish;
        end
        if (!$value$plusargs("MASK_OFF=%d", MASK_OFF_I)) MASK_OFF_I = 0;
        mask_en = (MASK_OFF_I == 0);
        use_fixseed = $value$plusargs("FIXSEED=%d", FIXSEED_I);
        fixseed_state = FIXSEED_I;
        $display("[MASK] mask_en=%0d  traces=%0d (%0d fixed + %0d random)  fixseed=%0s",
                 mask_en, NTRACES, NTRACES/2, NTRACES/2, use_fixseed ? "set" : "default");

        // fixed weight matrix: own seed if +FIXSEED, else the bench PRNG
        for (r = 0; r < ROWS; r = r + 1)
            for (c = 0; c < COLS; c = c + 1)
                fix_w[r][c] = use_fixseed ? $random(fixseed_state) : rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});

        sca_open_meta("systolic_array_wmask_shared", CLK_NS, CAPTURE);
        $display("[SCA] array geometry ROWS=%0d COLS=%0d SW=%0d capture=%0d cycles",
                 ROWS, COLS, u_dut.SW, CAPTURE);

        reset_n      = 1'b0;
        wt_load      = 1'b0;
        mask_refresh = 1'b0;
        wt_flat      = {(COLS*N){1'b0}};
        valid_act_in = {ROWS{1'b0}};
        act_flat     = {(ROWS*N){1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw the random matrix and the activation tile for BOTH groups
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    cur_w[r][c] = rand_i8(0);
            for (k = 0; k < STREAM_LEN; k = k + 1)
                for (r = 0; r < ROWS; r = r + 1)
                    act_tile[k][r] = rand_i8(0);

            if (!eff) begin
                if (TVLA_TARGET == "row0") begin
                    for (c = 0; c < COLS; c = c + 1) cur_w[0][c] = fix_w[0][c];
                end else begin
                    for (r = 0; r < ROWS; r = r + 1)
                        for (c = 0; c < COLS; c = c + 1)
                            cur_w[r][c] = fix_w[r][c];
                end
            end

            // ---- mask refresh + weight load, untriggered (R4) ----
            refresh_masks;
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
                    idx = cyc - r;                       // row r delayed r cycles
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
