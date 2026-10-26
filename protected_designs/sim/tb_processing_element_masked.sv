`timescale 1ns/1ps

module tb_processing_element_masked;

    localparam integer N = 8;
    localparam integer SHARE_W = 32;
    localparam integer RANDOM_TESTS = 1000;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n;
    reg wt_load;
    reg [SHARE_W-1:0] wt0_in, wt1_in;
    reg valid_in;
    reg signed [N-1:0] act_in;
    reg [SHARE_W-1:0] psum0_in, psum1_in;

    wire valid_out;
    wire [SHARE_W-1:0] wt0_out, wt1_out;
    wire signed [N-1:0] act_out;
    wire [SHARE_W-1:0] psum0_out, psum1_out;

    reg [SHARE_W-1:0] model_wt0, model_wt1;
    reg [SHARE_W-1:0] expected_psum0, expected_psum1;
    reg signed [63:0] signed_act;
    reg signed [63:0] unsigned_wt0_ext, unsigned_wt1_ext;
    reg signed [63:0] product0, product1;

    integer tests = 0;
    integer errors = 0;
    integer i;

    processing_element_masked #(
        .N(N),
        .SHARE_W(SHARE_W)
    ) dut (
        .clk       (clk),
        .reset_n   (reset_n),
        .wt_load   (wt_load),
        .wt0_in    (wt0_in),
        .wt1_in    (wt1_in),
        .valid_in  (valid_in),
        .act_in    (act_in),
        .psum0_in  (psum0_in),
        .psum1_in  (psum1_in),
        .valid_out (valid_out),
        .wt0_out   (wt0_out),
        .wt1_out   (wt1_out),
        .act_out   (act_out),
        .psum0_out (psum0_out),
        .psum1_out (psum1_out)
    );

    // Drive on the falling edge, check registered outputs after the rising edge.
    // The model uses the weight registers from BEFORE this edge, matching
    // nonblocking-assignment semantics in the DUT.
    task step;
        input reset_n_i;
        input wt_load_i;
        input [SHARE_W-1:0] wt0_i;
        input [SHARE_W-1:0] wt1_i;
        input valid_i;
        input [N-1:0] act_i;
        input [SHARE_W-1:0] psum0_i;
        input [SHARE_W-1:0] psum1_i;
        begin
            @(negedge clk);
            reset_n = reset_n_i;
            wt_load = wt_load_i;
            wt0_in = wt0_i;
            wt1_in = wt1_i;
            valid_in = valid_i;
            act_in = act_i;
            psum0_in = psum0_i;
            psum1_in = psum1_i;

            // Calculate expected arithmetic using the currently stored shares.
            signed_act = $signed(act_i);
            unsigned_wt0_ext = $signed({1'b0, model_wt0});
            unsigned_wt1_ext = $signed({1'b0, model_wt1});
            product0 = signed_act * unsigned_wt0_ext;
            product1 = signed_act * unsigned_wt1_ext;
            expected_psum0 = psum0_i + product0[SHARE_W-1:0];
            expected_psum1 = psum1_i + product1[SHARE_W-1:0];

            @(posedge clk);
            #1;
            tests = tests + 1;

            if (!reset_n_i) begin
                model_wt0 = {SHARE_W{1'b0}};
                model_wt1 = {SHARE_W{1'b0}};

                if (valid_out !== 1'b0 ||
                    act_out !== {N{1'b0}} ||
                    wt0_out !== {SHARE_W{1'b0}} ||
                    wt1_out !== {SHARE_W{1'b0}} ||
                    psum0_out !== {SHARE_W{1'b0}} ||
                    psum1_out !== {SHARE_W{1'b0}}) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: reset outputs incorrect", tests);
                end
            end else begin
                if (psum0_out !== expected_psum0) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: psum0 got=%08h expected=%08h",
                             tests, psum0_out, expected_psum0);
                end
                if (psum1_out !== expected_psum1) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: psum1 got=%08h expected=%08h",
                             tests, psum1_out, expected_psum1);
                end
                if (act_out !== $signed(act_i)) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: act_out got=%0h expected=%0h",
                             tests, act_out, act_i);
                end
                if (valid_out !== valid_i) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: valid_out got=%b expected=%b",
                             tests, valid_out, valid_i);
                end

                // Weight outputs reflect a load on this edge.
                if (wt_load_i) begin
                    model_wt0 = wt0_i;
                    model_wt1 = wt1_i;
                end

                if (wt0_out !== model_wt0) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: wt0_out got=%08h expected=%08h",
                             tests, wt0_out, model_wt0);
                end
                if (wt1_out !== model_wt1) begin
                    errors = errors + 1;
                    $display("FAIL cycle %0d: wt1_out got=%08h expected=%08h",
                             tests, wt1_out, model_wt1);
                end
            end
        end
    endtask

    initial begin
        reset_n = 1'b0;
        wt_load = 1'b0;
        wt0_in = 0;
        wt1_in = 0;
        valid_in = 0;
        act_in = 0;
        psum0_in = 0;
        psum1_in = 0;
        model_wt0 = 0;
        model_wt1 = 0;

        // Reset and basic loading/operation.
        step(0, 0, 0, 0, 0, 0, 0, 0);
        step(1, 1, 32'd7, 32'd11, 1, 8'd3, 0, 0);
        step(1, 0, 0, 0, 1, 8'd3, 32'd100, 32'd200);
        step(1, 0, 0, 0, 0, -8'sd2, 32'd10, 32'd20);
        step(1, 1, 32'hFFFF_FFFF, 32'h8000_0000, 1, -8'sd128, 0, 0);
        step(1, 0, 0, 0, 1, -8'sd1, 32'hFFFF_FFF0, 32'h7FFF_FFF0);

        // Randomized cycles. Occasionally load new shares; randomize all
        // arithmetic inputs to exercise modulo-2^SHARE_W accumulation.
        for (i = 0; i < RANDOM_TESTS; i = i + 1) begin
            step(
                1'b1,
                (($random & 32'h7) == 0),
                {$random},
                {$random},
                $random,
                $random,
                {$random},
                {$random}
            );
        end

        // Check reset assertion after active operation.
        step(0, 0, 0, 0, 1, -8'sd5, 32'h1234_5678, 32'h8765_4321);

        $display("");
        $display("PE tests run : %0d", tests);
        $display("Failures     : %0d", errors);
        if (errors == 0)
            $display("PASS: processing_element_masked passed all tests.");
        else
            $display("FAIL: processing_element_masked had %0d failure(s).", errors);
        $finish;
    end

endmodule
