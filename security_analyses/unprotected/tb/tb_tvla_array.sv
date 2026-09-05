`timescale 1ns/1ps
//=====================================================================
// tb_tvla_array.v -- TVLA dataset generation for the ROWSxCOLS
//                    weight-stationary systolic array.
//
// This is the array-size sweep vehicle: override ROWS/COLS at compile
// time (-PROWS=n -PCOLS=n) to walk the 1x1 -> 2x2 -> 4x4 -> 5x5 -> 8x8
// -> 16x16 ladder. Algorithmic noise from parallel PEs grows with array
// size, so trace-count-to-detection is expected to grow with it too;
// that curve is the measurement, not a nuisance.
//
// Two structural rules are load-bearing here:
//   * The input skew and output de-skew chains live in the TESTBENCH,
//     not in the DUT. systolic_array.v is a bare mesh by design. Skew
//     shift registers are wide, heavily toggling, and completely
//     data-dependent; inside the dumped scope they would swamp the PE
//     switching activity we actually want to characterise.
//   * The weight-load phase (ROWS cycles of downward shifting through
//     the wt_out chain) is untriggered. Loading pushes each secret
//     weight through every PE above its destination -- an enormous,
//     trivially detectable, and operationally irrelevant leak.
//=====================================================================
module tb_tvla_array;

    parameter N    = 8;
    parameter ACCW = 32;
    parameter ROWS = 5;
    parameter COLS = 5;

    localparam real CLK_NS = 10.0;

    // STREAM_LEN activation column-vectors are pushed into the west edge.
    // The window must also cover fill (ROWS-1 skew) and drain (COLS+1)
    // so the whole wavefront is inside the trace.
    localparam STREAM_LEN = 4;
    localparam CAPTURE    = STREAM_LEN + ROWS + COLS;
    localparam FLUSH      = ROWS + COLS + 2;   // fully quiesce between traces

    reg                      clk = 1'b0;
    reg                      reset_n, wt_load;
    reg  [COLS*N-1:0]        wt_flat;
    reg  [ROWS-1:0]          valid_act_in;
    reg  [ROWS*N-1:0]        act_flat;
    reg  [COLS*ACCW-1:0]     psum_flat;
    wire [COLS*ACCW-1:0]     psum_out;
    wire [COLS-1:0]          valid_sum_out;
    wire [ROWS*N-1:0]        act_out;
    wire [ROWS-1:0]          valid_act_out;

    (* dont_touch = "yes" *)
    systolic_array #(.N(N), .ACCW(ACCW), .ROWS(ROWS), .COLS(COLS)) u_dut (
        .clk(clk), .reset_n(reset_n),
        .wt_load(wt_load), .wt_flat(wt_flat),
        .valid_act_in(valid_act_in), .act_flat(act_flat),
        .psum_flat(psum_flat),
        .psum_out(psum_out), .valid_sum_out(valid_sum_out),
        .act_out(act_out), .valid_act_out(valid_act_out)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    //-----------------------------------------------------------------
    // Stimulus storage. A trace applies an STREAM_LEN x ROWS activation
    // tile; row r is delayed by r cycles (the skew), applied here in the
    // TB so no shift-register toggling enters the DUT scope.
    //-----------------------------------------------------------------
    reg signed [N-1:0] act_tile [0:STREAM_LEN-1][0:ROWS-1];
    reg signed [N-1:0] fix_tile [0:STREAM_LEN-1][0:ROWS-1];
    reg signed [N-1:0] secret_w [0:ROWS-1][0:COLS-1];   // resident weights
    reg signed [N-1:0] rand_w   [0:ROWS-1][0:COLS-1];

    integer t, k, r, c, cyc, idx;
    reg grp, eff;
    reg signed [N-1:0] tmp8;

    //-----------------------------------------------------------------
    // Weight load: wt_flat is the north edge; PE(r,c) forwards wt_reg
    // south, so ROWS cycles of wt_load fill the column. Row ROWS-1 must
    // be driven first because it travels furthest.
    //-----------------------------------------------------------------
    task load_weights(input integer use_random);
        integer rr, cc;
        begin
            for (rr = ROWS-1; rr >= 0; rr = rr - 1) begin
                @(negedge clk);
                wt_load = 1'b1;
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    tmp8 = use_random ? rand_w[rr][cc] : secret_w[rr][cc];
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
        sca_get_config("array");

        for (r = 0; r < ROWS; r = r + 1)
            for (c = 0; c < COLS; c = c + 1)
                secret_w[r][c] = rand_i8(0);

        for (k = 0; k < STREAM_LEN; k = k + 1)
            for (r = 0; r < ROWS; r = r + 1)
                fix_tile[k][r] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);                     // SCOPE-LIMITED: bare mesh only

        sca_open_meta("systolic_array", CLK_NS, CAPTURE);
        $display("[SCA] array geometry ROWS=%0d COLS=%0d ACCW=%0d capture=%0d cycles",
                 ROWS, COLS, ACCW, CAPTURE);

        reset_n      = 1'b0;
        wt_load      = 1'b0;
        wt_flat      = {(COLS*N){1'b0}};
        valid_act_in = {ROWS{1'b0}};
        act_flat     = {(ROWS*N){1'b0}};
        psum_flat    = {(COLS*ACCW){1'b0}};      // single tile: no north injection
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw the full random stimulus set for both groups.
            for (r = 0; r < ROWS; r = r + 1)
                for (c = 0; c < COLS; c = c + 1)
                    rand_w[r][c] = rand_i8(0);
            for (k = 0; k < STREAM_LEN; k = k + 1)
                for (r = 0; r < ROWS; r = r + 1)
                    act_tile[k][r] = rand_i8(0);

            if (TVLA_TARGET == "wt") begin
                // weights carry the contrast; activations held fixed
                for (k = 0; k < STREAM_LEN; k = k + 1)
                    for (r = 0; r < ROWS; r = r + 1)
                        act_tile[k][r] = fix_tile[k][r];
            end else if (TVLA_TARGET == "row0") begin
                // ONE row carries the contrast; every other row stays random
                // in BOTH populations. This is the configuration to use for
                // the array-size sweep. Randomising the whole tile instead
                // (TVLA_TARGET="act") makes the signal scale with the array
                // just as fast as the noise does, so TTD stays flat or even
                // falls with array size -- which is the opposite of the
                // algorithmic-noise effect the sweep is meant to measure.
                // With a single target row, the other ROWS-1 rows of PEs are
                // genuine algorithmic noise and TTD grows with the PE count.
                if (!eff)
                    for (k = 0; k < STREAM_LEN; k = k + 1)
                        act_tile[k][0] = fix_tile[k][0];
            end else if (!eff) begin
                for (k = 0; k < STREAM_LEN; k = k + 1)
                    for (r = 0; r < ROWS; r = r + 1)
                        act_tile[k][r] = fix_tile[k][r];
            end

            // ---- weight load, untriggered (R4) ----
            load_weights((TVLA_TARGET == "wt") && eff);

            // ---- flush, untriggered ----
            @(negedge clk);
            valid_act_in = {ROWS{1'b0}};
            act_flat     = {(ROWS*N){1'b0}};
            repeat (FLUSH) @(posedge clk);

            // ---- capture window: skewed activation wavefront ----
            for (cyc = 0; cyc < CAPTURE; cyc = cyc + 1) begin
                @(negedge clk);          // drive off the negedge (see note)
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
