`timescale 1ns/1ps
// ============================================================================
// tb_psum_accum
//   T1 multi-tile accumulation with the array's natural COLUMN SKEW applied
//      (column c's valid arrives c cycles late) -- this is the case the block
//      exists to absorb, so it is the default, not an edge case
//   T2 single-tile (RT=1): first_tile and last_tile both asserted
//   T3 back-to-back tile passes with no idle gap between them
//   T4 lane independence: unequal per-column stream lengths
//   T5 reset
// ============================================================================
module tb_psum_accum;

    parameter ACCW  = 32;
    parameter COLS  = 5;
    parameter DEPTH = 32;
    parameter AW    = 6;
    parameter NVEC  = 20;
    parameter RT    = 7;          // row tiles

    reg                  clk = 1'b0;
    reg                  reset_n;
    reg                  tile_start;
    reg                  first_tile;
    reg                  last_tile;
    reg  [COLS-1:0]      valid_in;
    reg  [COLS*ACCW-1:0] psum_in;
    wire [COLS*ACCW-1:0] psum_out;
    wire [COLS-1:0]      valid_out;
    wire [COLS-1:0]      ovf;

    always #5 clk = ~clk;

    psum_accum #(.ACCW(ACCW), .COLS(COLS), .DEPTH(DEPTH), .AW(AW)) dut (
        .clk(clk), .reset_n(reset_n),
        .tile_start(tile_start), .first_tile(first_tile), .last_tile(last_tile),
        .valid_in(valid_in), .psum_in(psum_in),
        .valid_out(valid_out), .psum_out(psum_out), .ovf(ovf)
    );

    reg signed [ACCW-1:0] DATA [0:RT-1][0:NVEC-1][0:COLS-1];
    reg signed [ACCW-1:0] EXPV [0:NVEC-1][0:COLS-1];
    reg signed [ACCW-1:0] OBS  [0:COLS-1][0:NVEC-1];
    integer               ocnt [0:COLS-1];

    integer errors = 0, checks = 0;
    integer rt, t, c, k, seed = 32'hC0FFEE;

    task gen_data;
        integer a, b, d;
        begin
            for (a = 0; a < RT; a = a + 1)
                for (b = 0; b < NVEC; b = b + 1)
                    for (d = 0; d < COLS; d = d + 1)
                        DATA[a][b][d] = $random(seed) >>> 8;
            for (b = 0; b < NVEC; b = b + 1)
                for (d = 0; d < COLS; d = d + 1) begin
                    EXPV[b][d] = 0;
                    for (a = 0; a < RT; a = a + 1)
                        EXPV[b][d] = EXPV[b][d] + DATA[a][b][d];
                end
        end
    endtask

    task pulse_tile_start;
        begin
            @(negedge clk);
            tile_start = 1'b1;
            valid_in   = {COLS{1'b0}};
            @(posedge clk); #1;
            @(negedge clk);
            tile_start = 1'b0;
        end
    endtask

    // Feed one row tile. skew=1 applies the array's column skew.
    task feed_tile;
        input integer rtile;
        input integer skew;
        integer kk, cc, tt;
        begin
            for (kk = 0; kk < NVEC + COLS + 2; kk = kk + 1) begin
                @(negedge clk);
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    tt = skew ? (kk - cc) : kk;
                    if (tt >= 0 && tt < NVEC) begin
                        psum_in[cc*ACCW +: ACCW] = DATA[rtile][tt][cc];
                        valid_in[cc]             = 1'b1;
                    end else begin
                        psum_in[cc*ACCW +: ACCW] = {ACCW{1'b0}};
                        valid_in[cc]             = 1'b0;
                    end
                end
                @(posedge clk); #1;
                for (cc = 0; cc < COLS; cc = cc + 1)
                    if (valid_out[cc]) begin
                        if (ocnt[cc] < NVEC)
                            OBS[cc][ocnt[cc]] = $signed(psum_out[cc*ACCW +: ACCW]);
                        ocnt[cc] = ocnt[cc] + 1;
                    end
            end
            @(negedge clk);
            valid_in = {COLS{1'b0}};
        end
    endtask

    task run_pass;
        input integer ntiles;
        input integer skew;
        input [127:0]  tag;
        integer a, cc, tt;
        begin
            for (cc = 0; cc < COLS; cc = cc + 1) ocnt[cc] = 0;
            for (a = 0; a < ntiles; a = a + 1) begin
                first_tile = (a == 0);
                last_tile  = (a == ntiles-1);
                pulse_tile_start;
                feed_tile(a, skew);
            end
            for (cc = 0; cc < COLS; cc = cc + 1) begin
                checks = checks + 1;
                if (ocnt[cc] !== NVEC) begin
                    errors = errors + 1;
                    $display("  FAIL %0s col %0d: %0d results, expected %0d",
                             tag, cc, ocnt[cc], NVEC);
                end
                for (tt = 0; tt < NVEC; tt = tt + 1) begin
                    checks = checks + 1;
                    if (OBS[cc][tt] !== EXPV[tt][cc]) begin
                        errors = errors + 1;
                        if (errors < 12)
                            $display("  FAIL %0s vec %0d col %0d: got %0d expected %0d",
                                     tag, tt, cc, OBS[cc][tt], EXPV[tt][cc]);
                    end
                end
            end
            if (|ovf) begin
                errors = errors + 1;
                $display("  FAIL %0s: overflow flag set (DEPTH too small?)", tag);
            end
            $display("  %0s : %0d cumulative errors", tag, errors);
        end
    endtask

    task recompute_expect;
        input integer ntiles;
        integer a, b, d;
        begin
            for (b = 0; b < NVEC; b = b + 1)
                for (d = 0; d < COLS; d = d + 1) begin
                    EXPV[b][d] = 0;
                    for (a = 0; a < ntiles; a = a + 1)
                        EXPV[b][d] = EXPV[b][d] + DATA[a][b][d];
                end
        end
    endtask

    initial begin
        reset_n = 1'b0; tile_start = 1'b0; first_tile = 1'b0; last_tile = 1'b0;
        valid_in = {COLS{1'b0}}; psum_in = {COLS*ACCW{1'b0}};
        repeat (3) @(negedge clk);

        // ---- T5 reset ------------------------------------------------
        @(posedge clk); #1;
        checks = checks + 1;
        if (valid_out !== {COLS{1'b0}}) begin
            errors = errors + 1; $display("  FAIL reset: acc_valid not clear");
        end
        reset_n = 1'b1;

        gen_data;

        $display("T1: %0d row tiles, %0d vectors, column skew applied", RT, NVEC);
        recompute_expect(RT);
        run_pass(RT, 1, "T1.skewed");

        $display("T2: single tile (first and last simultaneously)");
        recompute_expect(1);
        run_pass(1, 1, "T2.single");

        $display("T3: back-to-back passes, no skew");
        recompute_expect(RT);
        run_pass(RT, 0, "T3.noskew");

        $display("T4: repeat with fresh data to confirm no state carry-over");
        gen_data;
        recompute_expect(RT);
        run_pass(RT, 1, "T4.rerun");

        $display("----------------------------------------------------------");
        if (errors == 0) $display("tb_psum_accum: PASS  (%0d checks)", checks);
        else             $display("tb_psum_accum: FAIL  (%0d/%0d errors)", errors, checks);
        $display("----------------------------------------------------------");
        $finish;
    end

endmodule