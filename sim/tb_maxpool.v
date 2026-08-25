`timescale 1ns/1ps
// ============================================================================
// tb_maxpool_unit
//   T1 fixed windows (2,3,4,8) over random streams
//   T2 window length changing between windows
//   T3 all-negative streams (checks the MOST_NEG initialiser, the usual bug)
//   T4 duplicate maxima and monotonic streams (comparator tie handling)
//   T5 valid gating: bubbles must not advance the window
//   T6 win_len = 1 (pass-through)
// ============================================================================
module tb_maxpool_unit;

    parameter N  = 8;
    parameter CW = 5;

    reg                clk = 1'b0;
    reg                reset_n;
    reg                valid_in;
    reg        [CW-1:0] win_len;
    reg signed [N-1:0] x_in;
    wire               valid_out;
    wire signed [N-1:0] y_out;

    always #5 clk = ~clk;

    maxpool_unit #(.N(N), .CW(CW)) dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .win_len(win_len), .x_in(x_in), .valid_out(valid_out), .y_out(y_out)
    );

    integer errors = 0, checks = 0;
    integer i, j, w, nw, seed = 32'hBEEF;
    reg signed [N-1:0] run;
    reg signed [N-1:0] xv;

    // feed one window and check the emitted maximum
    task run_window;
        input integer        wl;
        input integer        mode;   // 0 random, 1 all-neg, 2 monotonic, 3 dup-max
        input integer        bubbles;
        integer p;
        begin
            run = -128;
            for (p = 0; p < wl; p = p + 1) begin
                case (mode)
                    1: xv = -8'sd1 - (($random(seed) & 8'h7F) % 127);
                    2: xv = p[N-1:0] - 8'sd64;
                    3: xv = (p % 2) ? 8'sd77 : -8'sd5;
                    default: xv = $random(seed);
                endcase
                if (xv > run) run = xv;

                // optional bubble before the sample: must not advance the window
                if (bubbles && (p % 2 == 0)) begin
                    @(negedge clk);
                    valid_in = 1'b0;
                    x_in     = 8'sd127;          // must be ignored entirely
                    @(posedge clk); #1;
                    if (valid_out !== 1'b0) begin
                        errors = errors + 1;
                        if (errors < 12) $display("  FAIL: output during bubble");
                    end
                end

                @(negedge clk);
                valid_in = 1'b1;
                x_in     = xv;
                win_len  = wl[CW-1:0];
                @(posedge clk); #1;
                checks = checks + 1;
                if (p == wl-1) begin
                    if (valid_out !== 1'b1) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL wl=%0d: no valid at window end", wl);
                    end else if (y_out !== run) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL wl=%0d mode=%0d: got %0d expected %0d",
                                     wl, mode, y_out, run);
                    end
                end else if (valid_out !== 1'b0) begin
                    errors = errors + 1;
                    if (errors < 12)
                        $display("  FAIL wl=%0d: early valid at sample %0d", wl, p);
                end
            end
            @(negedge clk);
            valid_in = 1'b0;
        end
    endtask

    initial begin
        reset_n = 1'b0; valid_in = 1'b0; win_len = 5'd4; x_in = 0;
        repeat (3) @(negedge clk);
        @(posedge clk); #1;
        checks = checks + 1;
        if (valid_out !== 1'b0) begin errors = errors + 1; $display("  FAIL reset"); end
        reset_n = 1'b1;

        $display("T1: fixed windows over random streams");
        for (w = 0; w < 4; w = w + 1) begin
            nw = (w == 0) ? 2 : (w == 1) ? 3 : (w == 2) ? 4 : 8;
            for (i = 0; i < 40; i = i + 1) run_window(nw, 0, 0);
        end

        $display("T2: window length varying between windows");
        for (i = 0; i < 60; i = i + 1) run_window(2 + (i % 7), 0, 0);

        $display("T3: all-negative streams");
        for (i = 0; i < 40; i = i + 1) run_window(4, 1, 0);

        $display("T4: monotonic and duplicate-maximum streams");
        for (i = 0; i < 30; i = i + 1) run_window(6, 2, 0);
        for (i = 0; i < 30; i = i + 1) run_window(6, 3, 0);

        $display("T5: bubbles interleaved with valid samples");
        for (i = 0; i < 40; i = i + 1) run_window(4, 0, 1);

        $display("T6: win_len = 1 (pass-through)");
        for (i = 0; i < 30; i = i + 1) run_window(1, 0, 0);

        $display("----------------------------------------------------------");
        if (errors == 0) $display("tb_maxpool_unit: PASS  (%0d checks)", checks);
        else             $display("tb_maxpool_unit: FAIL  (%0d/%0d errors)", errors, checks);
        $display("----------------------------------------------------------");
        $finish;
    end

endmodule