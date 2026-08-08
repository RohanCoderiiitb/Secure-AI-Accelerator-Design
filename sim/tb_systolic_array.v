`timescale 1ns/1ps
// ============================================================================
// tb_systolic_array
//   T1 : random INT8 weight tile, random activation stream
//   T2 : corner-value tile (-128 / +127 / 0) -- catches sign-extension and
//        Baugh-Wooley MSB-compensation bugs
//   T3 : weight reload -- proves the shift chain fully displaces the old tile
//   T4 : psum_north injection (vertical tiling / multi-tile accumulation)
//   T5 : identity tile -- column j must reproduce activation element j
//
// Change the array size by overriding ROWS/COLS ONLY, e.g.
//   iverilog -g2005 -Ptb_systolic_array.ROWS=4 -Ptb_systolic_array.COLS=4 ...
// ============================================================================
module tb_systolic_array;

    parameter ROWS = 16;
    parameter COLS = 16;
    parameter N    = 8;
    parameter ACCW = 32;
    parameter NVEC = 40;              // activation vectors streamed per test

    // ------------------------------------------------------------------
    reg                     clk = 1'b0;
    reg                     reset_n;
    reg                     wt_load;
    reg  [COLS*N-1:0]       wt_flat;
    reg  [ROWS*N-1:0]       act_flat;
    reg  [ROWS-1:0]         valid_act_in;
    reg  [COLS*ACCW-1:0]    psum_flat;

    wire [COLS*ACCW-1:0]    psum_out;
    wire [COLS-1:0]         valid_sum_out;
    wire [ROWS*N-1:0]       act_out;
    wire [ROWS-1:0]         valid_act_out;

    always #5 clk = ~clk;

    systolic_array #(
        .ROWS(ROWS), .COLS(COLS), .N(N), .ACCW(ACCW)
    ) dut (
        .clk(clk), .reset_n(reset_n),
        .wt_load(wt_load), .wt_flat(wt_flat),
        .act_flat(act_flat), .valid_act_in(valid_act_in),
        .psum_flat(psum_flat),
        .psum_out(psum_out), .valid_sum_out(valid_sum_out),
        .act_out(act_out), .valid_act_out(valid_act_out)
    );

    // ------------------------------------------------------------------
    // unpacked mirrors of the flattened ports (TB convenience only)
    // ------------------------------------------------------------------
    reg signed [N-1:0]    W    [0:ROWS-1][0:COLS-1];
    reg signed [N-1:0]    A    [0:NVEC-1][0:ROWS-1];
    reg signed [ACCW-1:0] EXPV [0:NVEC-1][0:COLS-1];
    reg signed [ACCW-1:0] OBS  [0:COLS-1][0:NVEC-1];
    reg signed [ACCW-1:0] PINJ [0:COLS-1];
    integer               ocnt [0:COLS-1];

    integer errors = 0;
    integer checks = 0;
    integer i, j, k, t, c, tst;

    // ------------------------------------------------------------------
    task pack_wt;                      // W[row] -> wt_flat
        input integer row;
        integer cc;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1)
                wt_flat[cc*N +: N] = W[row][cc];
        end
    endtask

    task clear_acts;
        integer rr;
        begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                act_flat[rr*N +: N] = {N{1'b0}};
            valid_act_in = {ROWS{1'b0}};
        end
    endtask

    task pack_psum_north;
        integer cc;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1)
                psum_flat[cc*ACCW +: ACCW] = PINJ[cc];
        end
    endtask

    // ------------------------------------------------------------------
    // Shift the ROWS x COLS weight tile in from the north edge.
    // The first word pushed ends up in the BOTTOM row, so feed rows in
    // reverse order: W[ROWS-1] first, W[0] last.
    // ------------------------------------------------------------------
    task load_weights;
        integer s;
        begin
            clear_acts;
            for (s = 0; s < ROWS; s = s + 1) begin
                @(negedge clk);
                wt_load = 1'b1;
                pack_wt(ROWS-1-s);
                @(posedge clk);
            end
            @(negedge clk);
            wt_load = 1'b0;
        end
    endtask

    // ------------------------------------------------------------------
    // Stream NVEC activation vectors with the required row skew and pop
    // the south-edge results. Column outputs arrive in strict vector
    // order, so no explicit de-skew arithmetic is needed here.
    // ------------------------------------------------------------------
    task stream_and_collect;
        integer kk, ii, cc, tt;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1) ocnt[cc] = 0;

            for (kk = 0; kk < NVEC + ROWS + COLS + 8; kk = kk + 1) begin
                @(negedge clk);
                for (ii = 0; ii < ROWS; ii = ii + 1) begin
                    tt = kk - ii;                       // row i is delayed by i
                    if (tt >= 0 && tt < NVEC) begin
                        act_flat[ii*N +: N] = A[tt][ii];
                        valid_act_in[ii]           = 1'b1;
                    end else begin
                        act_flat[ii*N +: N] = {N{1'b0}};
                        valid_act_in[ii]           = 1'b0;
                    end
                end
                @(posedge clk); #1;
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    if (valid_sum_out[cc]) begin
                        if (ocnt[cc] < NVEC)
                            OBS[cc][ocnt[cc]] = $signed(psum_out[cc*ACCW +: ACCW]);
                        ocnt[cc] = ocnt[cc] + 1;
                    end
                end
            end
            clear_acts;
        end
    endtask

    // ------------------------------------------------------------------
    task compute_reference;
        integer tt, ii, cc;
        reg signed [ACCW-1:0] acc;
        begin
            for (tt = 0; tt < NVEC; tt = tt + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    acc = PINJ[cc];
                    for (ii = 0; ii < ROWS; ii = ii + 1)
                        acc = acc + (A[tt][ii] * W[ii][cc]);
                    EXPV[tt][cc] = acc;
                end
        end
    endtask

    task check_results;
        input [255:0] tag;
        integer tt, cc;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1) begin
                checks = checks + 1;
                if (ocnt[cc] !== NVEC) begin
                    errors = errors + 1;
                    $display("  FAIL %0s: col %0d produced %0d valid outputs, expected %0d",
                             tag, cc, ocnt[cc], NVEC);
                end
                for (tt = 0; tt < NVEC; tt = tt + 1) begin
                    checks = checks + 1;
                    if (OBS[cc][tt] !== EXPV[tt][cc]) begin
                        errors = errors + 1;
                        if (errors < 15)
                            $display("  FAIL %0s: vec %0d col %0d : got %0d, expected %0d",
                                     tag, tt, cc, OBS[cc][tt], EXPV[tt][cc]);
                    end
                end
            end
        end
    endtask

    task run_test;
        input [255:0] tag;
        begin
            load_weights;
            pack_psum_north;
            compute_reference;
            stream_and_collect;
            check_results(tag);
            $display("  %0s : %0d cumulative errors", tag, errors);
        end
    endtask

    // ------------------------------------------------------------------
    integer seed = 32'h1234_5678;
    task randomise_acts;
        integer tt, ii;
        begin
            for (tt = 0; tt < NVEC; tt = tt + 1)
                for (ii = 0; ii < ROWS; ii = ii + 1)
                    A[tt][ii] = $random(seed);
        end
    endtask

    task randomise_weights;
        integer ii, cc;
        begin
            for (ii = 0; ii < ROWS; ii = ii + 1)
                for (cc = 0; cc < COLS; cc = cc + 1)
                    W[ii][cc] = $random(seed);
        end
    endtask

    task zero_injection;
        integer cc;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1) PINJ[cc] = {ACCW{1'b0}};
        end
    endtask

    // ==================================================================
    initial begin
        $display("==================================================");
        $display("systolic_array : ROWS=%0d COLS=%0d N=%0d ACCW=%0d",
                 ROWS, COLS, N, ACCW);
        $display("  %0d PEs, %0d Baugh-Wooley multipliers", ROWS*COLS, ROWS*COLS);
        $display("  fill/drain latency = ROWS + COLS = %0d cycles", ROWS+COLS);
        $display("==================================================");

        reset_n = 1'b0; wt_load = 1'b0;
        wt_flat = 0; psum_flat = 0;
        clear_acts;
        zero_injection;
        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        @(negedge clk);

        // ---- T1 : random tile ----------------------------------------
        $display("T1: random INT8 weight tile");
        randomise_weights; randomise_acts; zero_injection;
        run_test("T1.random");

        // ---- T2 : corner values --------------------------------------
        $display("T2: corner-value tile (-128 / +127 / 0)");
        for (i = 0; i < ROWS; i = i + 1)
            for (j = 0; j < COLS; j = j + 1)
                case ((i + j) % 4)
                    0: W[i][j] = -8'sd128;
                    1: W[i][j] =  8'sd127;
                    2: W[i][j] =  8'sd0;
                    default: W[i][j] = -8'sd1;
                endcase
        for (t = 0; t < NVEC; t = t + 1)
            for (i = 0; i < ROWS; i = i + 1)
                case ((t + i) % 4)
                    0: A[t][i] = -8'sd128;
                    1: A[t][i] =  8'sd127;
                    2: A[t][i] =  8'sd0;
                    default: A[t][i] = $random(seed);
                endcase
        zero_injection;
        run_test("T2.corners");

        // ---- T3 : weight reload --------------------------------------
        $display("T3: weight reload (old tile must be fully displaced)");
        randomise_weights; randomise_acts; zero_injection;
        run_test("T3.reload");

        // ---- T4 : psum_north injection -------------------------------
        $display("T4: north psum injection (vertical tiling)");
        randomise_weights; randomise_acts;
        for (c = 0; c < COLS; c = c + 1)
            PINJ[c] = $signed($random(seed)) >>> 8;   // keep well inside ACCW
        run_test("T4.psum_inject");

        // ---- T5 : identity tile --------------------------------------
        $display("T5: identity tile (column j must echo activation element j)");
        if (ROWS == COLS) begin
            for (i = 0; i < ROWS; i = i + 1)
                for (j = 0; j < COLS; j = j + 1)
                    W[i][j] = (i == j) ? 8'sd1 : 8'sd0;
            randomise_acts; zero_injection;
            run_test("T5.identity");
        end else begin
            $display("  (skipped: only meaningful for a square array)");
        end

        $display("==================================================");
        if (errors == 0) $display("tb_systolic_array: PASS  (%0d checks)", checks);
        else             $display("tb_systolic_array: FAIL  (%0d/%0d errors)", errors, checks);
        $display("==================================================");
        $finish;
    end

endmodule