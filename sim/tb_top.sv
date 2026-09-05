// Self-checking testbench for flexnn_top.
//
// Config: ARRAY_ROWS=2, ARRAY_COLS=2, WAVES=2, POOL_LEN=1 (pooling disabled).
// Chosen deliberately small so the expected result can be computed by hand
// and checked against, rather than trusting the DUT to grade itself.
//
// Activations (IC=ARRAY_ROWS=2, M=WAVES=2), A[wave][row]:
//   row0: wave0=1, wave1=2
//   row1: wave0=3, wave1=4
//
// Weights (IC=ARRAY_ROWS=2, OC=ARRAY_COLS=2), W[row][col]:
//   row0: col0=1, col1=2
//   row1: col0=3, col1=4
//
// Expected raw dot products C[wave][col] = sum_row A[wave][row]*W[row][col]:
//   C[0][0]=1*1+3*3=10   C[0][1]=1*2+3*4=14
//   C[1][0]=2*1+4*3=14   C[1][1]=2*2+4*4=20
//
// Requantize params are chosen so the INT8 output equals the raw psum
// exactly (bias=0, m0=256, shift=8 => scaled = biased + round(128/256) =
// biased, since the *256 is an exact multiple and adding half a step then
// flooring drops the fractional remainder cleanly). act_mode=PASS,
// pool_win_len=1 (POOL_LEN=1 => maxpool is a 1-sample passthrough).
// So of_rd_data_flat should come out exactly {10,14 / 14,20} as above.
`timescale 1ns/1ps
module tb_top;

    localparam N          = 8;
    localparam ACCW       = 32;
    localparam ARRAY_ROWS = 2;
    localparam ARRAY_COLS = 2;
    localparam WAVES      = 2;
    localparam MW         = 32;
    localparam SW         = 6;
    localparam POOL_LEN   = 1;

    localparam IF_DEPTH  = ARRAY_ROWS*WAVES;
    localparam FL_DEPTH  = ARRAY_ROWS*ARRAY_COLS;
    localparam OF_DEPTH  = WAVES/POOL_LEN;
    localparam IF_ADDR_W = (IF_DEPTH<=1)?1:$clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH<=1)?1:$clog2(FL_DEPTH);
    localparam OF_ADDR_W = (OF_DEPTH<=1)?1:$clog2(OF_DEPTH);
    localparam CW        = (POOL_LEN<=1)?1:$clog2(POOL_LEN+1);

    reg clk = 0;
    reg reset_n = 0;
    reg start = 0;
    wire done;
    wire array_compute_done;

    reg                    if_wr_en = 0;
    reg  [IF_ADDR_W-1:0]   if_wr_addr = 0;
    reg  [N-1:0]           if_wr_data = 0;

    reg                    fl_wr_en = 0;
    reg  [FL_ADDR_W-1:0]   fl_wr_addr = 0;
    reg  [N-1:0]           fl_wr_data = 0;

    reg  [ARRAY_COLS*ACCW-1:0] bias_flat = 0;
    reg  [ARRAY_COLS*MW-1:0]   m0_flat   = 0;
    reg  [ARRAY_COLS*SW-1:0]   shift_flat= 0;

    reg  [1:0] act_mode = 0;
    reg  signed [N-1:0] act_clamp_high = 0;
    reg  [2:0] act_leaky_shift = 0;
    reg  [CW-1:0] pool_win_len = 0;

    wire [ARRAY_COLS-1:0] psum_ovf_flat;
    wire [ARRAY_COLS-1:0] requant_sat_flat;

    reg  [ARRAY_COLS-1:0]           of_rd_en = 0;
    reg  [ARRAY_COLS*OF_ADDR_W-1:0] of_rd_addr_flat = 0;
    wire [ARRAY_COLS*N-1:0]         of_rd_data_flat;

    integer errors = 0;

    flexnn_top #(
        .N(N), .ACCW(ACCW), .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS),
        .WAVES(WAVES), .MW(MW), .SW(SW), .POOL_LEN(POOL_LEN)
    ) dut (
        .clk(clk), .reset_n(reset_n), .start(start), .done(done),
        .array_compute_done(array_compute_done),
        .if_wr_en(if_wr_en), .if_wr_addr(if_wr_addr), .if_wr_data(if_wr_data),
        .fl_wr_en(fl_wr_en), .fl_wr_addr(fl_wr_addr), .fl_wr_data(fl_wr_data),
        .bias_flat(bias_flat), .m0_flat(m0_flat), .shift_flat(shift_flat),
        .act_mode(act_mode), .act_clamp_high(act_clamp_high), .act_leaky_shift(act_leaky_shift),
        .pool_win_len(pool_win_len),
        .psum_ovf_flat(psum_ovf_flat), .requant_sat_flat(requant_sat_flat),
        .of_rd_en(of_rd_en), .of_rd_addr_flat(of_rd_addr_flat), .of_rd_data_flat(of_rd_data_flat)
    );

    // 10 ns period clock
    always #5 clk = ~clk;

    // ---- helper tasks ----
    task automatic write_if(input [IF_ADDR_W-1:0] a, input [N-1:0] d);
        begin
            @(negedge clk);
            if_wr_en   = 1'b1;
            if_wr_addr = a;
            if_wr_data = d;
            @(negedge clk);
            if_wr_en   = 1'b0;
        end
    endtask

    task automatic write_fl(input [FL_ADDR_W-1:0] a, input [N-1:0] d);
        begin
            @(negedge clk);
            fl_wr_en   = 1'b1;
            fl_wr_addr = a;
            fl_wr_data = d;
            @(negedge clk);
            fl_wr_en   = 1'b0;
        end
    endtask

    task automatic check_output(input [OF_ADDR_W-1:0] wave, input signed [N-1:0] exp_c0, input signed [N-1:0] exp_c1);
        reg signed [N-1:0] got0, got1;
        begin
            @(negedge clk);
            of_rd_en        = {ARRAY_COLS{1'b1}};
            of_rd_addr_flat = {2{wave}};
            @(negedge clk); // sram_2p / scratchpad: 1-cycle registered read
            got0 = of_rd_data_flat[0*N +: N];
            got1 = of_rd_data_flat[1*N +: N];
            of_rd_en = {ARRAY_COLS{1'b0}};

            if (got0 !== exp_c0) begin
                $display("MISMATCH wave=%0d col=0: expected %0d got %0d", wave, exp_c0, got0);
                errors = errors + 1;
            end else
                $display("OK       wave=%0d col=0: %0d", wave, got0);

            if (got1 !== exp_c1) begin
                $display("MISMATCH wave=%0d col=1: expected %0d got %0d", wave, exp_c1, got1);
                errors = errors + 1;
            end else
                $display("OK       wave=%0d col=1: %0d", wave, got1);
        end
    endtask

    integer timeout_cycles;
    reg saw_array_done;
    integer array_done_cycle;

    always @(posedge clk) begin
        if (array_compute_done) array_done_cycle <= timeout_cycles;
        if (array_compute_done) saw_array_done <= 1'b1;
    end

    initial begin
        $dumpfile("top.vcd");
        $dumpvars(0, tb_top);

        // ---- reset ----
        reset_n = 0;
        saw_array_done = 0;
        array_done_cycle = -1;
        repeat (4) @(negedge clk);
        reset_n = 1;
        @(negedge clk);

        // ---- preload activations: IF_GB[r*WAVES+k] = A[k][r] ----
        // row0: wave0=1, wave1=2 -> IF_GB[0]=1, IF_GB[1]=2
        // row1: wave0=3, wave1=4 -> IF_GB[2]=3, IF_GB[3]=4
        write_if(0, 8'd1);
        write_if(1, 8'd2);
        write_if(2, 8'd3);
        write_if(3, 8'd4);

        // ---- preload weights: FL_GB[row*ARRAY_COLS+c] = W[row][c] ----
        // row0: col0=1, col1=2 -> FL_GB[0]=1, FL_GB[1]=2
        // row1: col0=3, col1=4 -> FL_GB[2]=3, FL_GB[3]=4
        write_fl(0, 8'd1);
        write_fl(1, 8'd2);
        write_fl(2, 8'd3);
        write_fl(3, 8'd4);

        // ---- requantize params: identity passthrough per column ----
        bias_flat  = {ACCW'(0), ACCW'(0)};
        m0_flat    = {MW'(256), MW'(256)};
        shift_flat = {SW'(8),   SW'(8)};

        // ---- activation: pass-through ----
        act_mode        = 2'd0; // MODE_PASS
        act_clamp_high  = 8'sd127;
        act_leaky_shift = 3'd0;

        // ---- pooling: disabled (window = 1) ----
        pool_win_len = 1;

        // ---- kick off compute ----
        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // ---- wait for done, with a watchdog ----
        timeout_cycles = 0;
        while (!done && timeout_cycles < 500) begin
            @(negedge clk);
            timeout_cycles = timeout_cycles + 1;
        end

        if (!done) begin
            $display("TIMEOUT: done never asserted after %0d cycles", timeout_cycles);
            errors = errors + 1;
        end else begin
            $display("array_compute_done pulsed at cycle %0d, top-level done pulsed at cycle %0d (gap = %0d cycles of post-processing latency)",
                      array_done_cycle, timeout_cycles, timeout_cycles - array_done_cycle);
            if (!saw_array_done) begin
                $display("WARNING: array_compute_done never pulsed before done - ordering assumption is wrong");
                errors = errors + 1;
            end
        end

        @(negedge clk); // let done pulse pass

        // ---- read back and check ----
        check_output(0, 8'sd10, 8'sd14); // wave0: col0=10, col1=14
        check_output(1, 8'sd14, 8'sd20); // wave1: col0=14, col1=20

        if (errors == 0)
            $display("\n*** TEST PASSED ***\n");
        else
            $display("\n*** TEST FAILED: %0d error(s) ***\n", errors);

        $finish;
    end

endmodule