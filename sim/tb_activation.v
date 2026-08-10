`timescale 1ns/1ps
// ============================================================================
// tb_activation_unit
//   T1 exhaustive: all 256 inputs x 4 modes x several clamp_hi / leak_shift
//   T2 valid gating
//   T3 reset
//   T4 mode switching on consecutive cycles (no state may carry over)
// Latency is 1 register, and iteration k drives before edge k+1, so the
// result is observable within the same iteration.
// ============================================================================
module tb_activation_unit;

    parameter N = 8;

    reg                clk = 1'b0;
    reg                reset_n;
    reg                valid_in;
    reg        [1:0]   mode;
    reg signed [N-1:0] clamp_hi;
    reg        [2:0]   leak_shift;
    reg signed [N-1:0] x_in;
    wire               valid_out;
    wire signed [N-1:0] y_out;

    always #5 clk = ~clk;

    // Updated Instantiation to match activation_unit_2.v port mappings
    activation_unit #(.N(N)) dut (
        .clk(clk), 
        .reset_n(reset_n), 
        .mode(mode),
        .valid_in(valid_in),
        .x_in(x_in), 
        .clamp_high(clamp_hi),     // Mapped to your specific port name
        .leaky_shift(leak_shift),  // Mapped to your specific port name
        .valid_out(valid_out), 
        .y_out(y_out)
    );

    integer errors = 0, checks = 0;
    integer m, xi, ci, si;
    reg signed [N-1:0] xv, chv, exp;
    reg [2:0] lsv;

    function signed [N-1:0] ref_act;
        input        [1:0]   mo;
        input signed [N-1:0] x;
        input signed [N-1:0] chi;
        input        [2:0]   ls;
        begin
            case (mo)
                2'd1: ref_act = (x < 0) ? 8'sd0 : x;
                2'd2: ref_act = (x < 0) ? 8'sd0 : ((x > chi) ? chi : x);
                2'd3: ref_act = (x < 0) ? (x >>> ls) : x;
                default: ref_act = x;
            endcase
        end
    endfunction

    task drive_check;
        input        [1:0]   mo;
        input signed [N-1:0] x;
        input signed [N-1:0] chi;
        input        [2:0]   ls;
        input                v;
        begin
            @(negedge clk);
            mode = mo; x_in = x; clamp_hi = chi; leak_shift = ls; valid_in = v;
            exp  = ref_act(mo, x, chi, ls);
            @(posedge clk); #1;
            checks = checks + 1;
            if (valid_out !== v) begin
                errors = errors + 1;
                if (errors < 12) $display("  FAIL valid: %0b vs %0b", valid_out, v);
            end
            if (y_out !== exp) begin
                errors = errors + 1;
                if (errors < 12)
                    $display("  FAIL mode=%0d x=%0d chi=%0d ls=%0d : got %0d expected %0d",
                             mo, x, chi, ls, y_out, exp);
            end
        end
    endtask

    initial begin
        reset_n = 1'b0; valid_in = 1'b0; mode = 0;
        x_in = 0; clamp_hi = 0; leak_shift = 0;
        repeat (3) @(negedge clk);

        // ---- T3 reset ------------------------------------------------
        @(posedge clk); #1;
        checks = checks + 1;
        if (valid_out !== 1'b0 || y_out !== 0) begin
            errors = errors + 1; $display("  FAIL reset state");
        end
        reset_n = 1'b1;

        // ---- T1 exhaustive -------------------------------------------
        $display("T1: exhaustive sweep over all modes and inputs...");
        for (m = 0; m < 4; m = m + 1)
            for (ci = 0; ci < 4; ci = ci + 1) begin
                chv = (ci == 0) ? 8'sd6   :        // ReLU6
                      (ci == 1) ? 8'sd127 :
                      (ci == 2) ? 8'sd0   : 8'sd31;
                for (si = 0; si < 3; si = si + 1) begin
                    lsv = si[2:0] + 3'd1;          // 1..3
                    for (xi = 0; xi < 256; xi = xi + 1) begin
                        xv = xi[N-1:0];
                        drive_check(m[1:0], xv, chv, lsv, 1'b1);
                    end
                end
            end

        // ---- T2 valid gating -----------------------------------------
        $display("T2: valid gating...");
        for (xi = 0; xi < 256; xi = xi + 1)
            drive_check(2'd1, xi[N-1:0], 8'sd6, 3'd1, (xi % 3) != 0);

        // ---- T4 mode switching every cycle ----------------------------
        $display("T4: mode switching on consecutive cycles...");
        for (xi = 0; xi < 512; xi = xi + 1)
            drive_check(xi[1:0], $random, 8'sd6, 3'd2, 1'b1);

        $display("----------------------------------------------------------");
        if (errors == 0) $display("tb_activation_unit: PASS  (%0d checks)", checks);
        else             $display("tb_activation_unit: FAIL  (%0d/%0d errors)", errors, checks);
        $display("----------------------------------------------------------");
        $finish;
    end

endmodule