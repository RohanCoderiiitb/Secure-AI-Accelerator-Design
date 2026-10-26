`timescale 1ns/1ps

// Self-checking testbench for share_multiplier in masked_wt_multiplier.sv
module share_multiplier_tb;

    localparam integer N  = 8;
    localparam integer SW = 32;
    localparam integer RANDOM_TESTS = 10000;

    reg  [N-1:0]  a;
    reg  [SW-1:0] ws;
    wire [SW-1:0] p;

    reg [SW-1:0] expected;
    reg signed [63:0] signed_a;
    reg signed [63:0] signed_ws_extended;
    reg signed [63:0] full_product;

    integer tests;
    integer errors;
    integer i;

    share_multiplier #(
        .N(N),
        .SW(SW)
    ) dut (
        .a  (a),
        .ws (ws),
        .p  (p)
    );

    // Compute signed activation x unsigned share, retaining the low SW bits.
    task check_case;
        input [N-1:0]  a_in;
        input [SW-1:0] ws_in;
        begin
            a = a_in;
            ws = ws_in;
            #1;

            // Explicit sign extension for the signed activation.
            signed_a = $signed(a_in);

            // Extend ws with a leading zero so it is treated as non-negative.
            signed_ws_extended = $signed({1'b0, ws_in});
            full_product = signed_a * signed_ws_extended;
            expected = full_product[SW-1:0];

            tests = tests + 1;
            if (p !== expected) begin
                errors = errors + 1;
                $display("FAIL test %0d: a=0x%0h (%0d), ws=0x%0h, got=0x%0h, expected=0x%0h",
                         tests, a_in, $signed(a_in), ws_in, p, expected);
            end
        end
    endtask

    initial begin
        tests  = 0;
        errors = 0;
        a      = '0;
        ws     = '0;

        $display("Testing share_multiplier: N=%0d, SW=%0d", N, SW);

        // Directed activation corner cases, with representative share values.
        check_case(8'h00, 32'h0000_0000);
        check_case(8'h01, 32'h0000_0000);
        check_case(8'hFF, 32'h0000_0000); // -1 x 0
        check_case(8'h7F, 32'h0000_0001); // maximum positive activation
        check_case(8'h80, 32'h0000_0001); // minimum negative activation
        check_case(8'hFF, 32'h0000_0001); // -1 x 1
        check_case(8'h02, 32'h0000_0003);
        check_case(8'hFE, 32'h0000_0003); // -2 x 3
        check_case(8'h7F, 32'hFFFF_FFFF);
        check_case(8'h80, 32'hFFFF_FFFF);
        check_case(8'hFF, 32'hFFFF_FFFF);
        check_case(8'h55, 32'hAAAA_AAAA);
        check_case(8'hAA, 32'h5555_5555);
        check_case(8'h40, 32'h8000_0000);
        check_case(8'hC0, 32'h8000_0000);

        // Sweep all 256 activation encodings against several share patterns.
        for (i = 0; i < 256; i = i + 1) begin
            check_case(i[7:0], 32'h0000_0000);
            check_case(i[7:0], 32'h0000_0001);
            check_case(i[7:0], 32'h0000_00FF);
            check_case(i[7:0], 32'h8000_0000);
            check_case(i[7:0], 32'hFFFF_FFFF);
        end

        // Randomized tests. $random is used for broad simulator compatibility.
        for (i = 0; i < RANDOM_TESTS; i = i + 1) begin
            check_case($random, {$random, $random});
        end

        $display("");
        $display("Total tests : %0d", tests);
        $display("Failures    : %0d", errors);

        if (errors == 0)
            $display("PASS: all share_multiplier tests passed.");
        else
            $display("FAIL: share_multiplier has %0d mismatch(es).", errors);

        $finish;
    end

endmodule
