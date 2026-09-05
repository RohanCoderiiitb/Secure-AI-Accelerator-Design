`timescale 1ns/1ps
//=============================================================================
// tb_multiplier_eval.v
//
// Exhaustive, self-checking testbench for baugh_wooley_multiplier.
// Tests all 65,536 combinations for an 8x8 signed multiplier.
//=============================================================================

module tb_multiplier_eval;

    //-------------------------------------------------------------------
    // Test configuration
    //-------------------------------------------------------------------
    parameter N         = 8;      // must match DUT width
    parameter SETTLE_NS = 10;     // combinational settle time per vector

    //-------------------------------------------------------------------
    // DUT hookup
    //-------------------------------------------------------------------
    reg  [N-1:0]   x, y;
    wire [2*N-1:0] p;

    baugh_wooley_multiplier #(.N(N)) dut (
        .x(x),
        .y(y),
        .p(p)
    );

    //-------------------------------------------------------------------
    // Reference model (golden, signed) + scoreboard
    //-------------------------------------------------------------------
    integer errors;
    integer total_tests;

    task automatic apply_and_check(
        input [N-1:0] xv, 
        input [N-1:0] yv
    );
        reg signed [2*N-1:0] expected;
        begin
            x = xv;
            y = yv;
            #SETTLE_NS; // let combinational logic settle

            expected = $signed(xv) * $signed(yv);
            
            if (p !== expected[2*N-1:0]) begin
                errors = errors + 1;
                $display("[%0t] MISMATCH: x=%0d y=%0d dut_p=%0d (0x%h) expected=%0d (0x%h)",
                          $time, $signed(xv), $signed(yv), $signed(p), p, expected, expected[2*N-1:0]);
            end
            
            total_tests = total_tests + 1;
        end
    endtask

    //-------------------------------------------------------------------
    // Main stimulus
    //-------------------------------------------------------------------
    integer i, j;

    initial begin
        errors = 0;
        total_tests = 0;

        $display("========================================================");
        $display("Starting comprehensive functional evaluation...");
        $display("Testing all 2^%0d combinations for %0d-bit signed inputs...", 2*N, N);
        $display("========================================================");

        // Exhaustive sweep of all possible X and Y values
        for (i = 0; i < (1<<N); i = i + 1) begin
            for (j = 0; j < (1<<N); j = j + 1) begin
                apply_and_check(i[N-1:0], j[N-1:0]);
            end
        end

        //=================================================================
        // Summary
        //=================================================================
        $display("========================================================");
        $display("Evaluation Complete");
        $display("Total Vectors Tested : %0d", total_tests);
        $display("Functional Errors    : %0d", errors);
        if (errors == 0)
            $display("RESULT: PASS - Multiplier is 100%% functionally correct.");
        else
            $display("RESULT: FAIL - Found %0d mismatches (see log above).", errors);
        $display("========================================================");

        $finish;
    end

endmodule