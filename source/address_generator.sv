// Address generator for the systolic array's operand interface.
//
// Timing derivation (from processing_element.v + systolic_array.v, not
// assumed from the module name):
//
//   PE(r,c): psum_out <= psum_in + act_in*wt_reg   (registered, 1 cyc)
//            act_out  <= act_in                     (registered, 1 cyc, passes east)
//            act[r][0]      is fed COMBINATIONALLY from act_flat row r
//            psum[0][c]     is fed COMBINATIONALLY from psum_flat (tied 0, standalone tile)
//
// Solving the recurrence (see chat derivation) shows that for the array to
// compute a clean dot product per (wave k, column c):
//   C[k][c] = sum_r A[r][k] * W[r][c]
// activation row r must be FED (r cycles) later than row 0 - i.e. row r's
// wave-0 element must arrive on act_flat[r] exactly r cycles after row 0's
// wave-0 element. This module generates that per-row read schedule
// (the "input skew"), and on the output side, converts the naturally
// time-staggered per-column results (column c's wave k appears (c cycles
// later than column 0's wave k) into an aligned write address per column
// (the "output de-skew") - no physical delay line needed, just a
// per-column wave counter driven directly by valid_sum_out.
//
// Weight loading skew (feeding wt_flat) is generated separately in
// systolic_controller.sv, since it's a one-shot sequence (feed weight
// matrix rows in REVERSE order over ARRAY_ROWS cycles) rather than a
// per-cycle streaming schedule - simple enough to inline there.
module address_generator #(
    parameter ARRAY_ROWS = 4,
    parameter ARRAY_COLS = 4,
    parameter WAVES      = 4,                       // M: activation vectors per tile pass
    parameter WADDR_W    = (WAVES <= 1) ? 1 : $clog2(WAVES)
) (
    input  wire clk,
    input  wire reset_n,

    input  wire stream_start,     // 1-cycle pulse: begin a compute pass
    output reg  stream_busy,      // high while activation rows are still being issued
    output reg  compute_done,     // 1-cycle pulse: last column's last wave has been captured

    // Activation scratchpad read ports (one per array row)
    output reg  [ARRAY_ROWS-1:0]              act_rd_en,
    output reg  [ARRAY_ROWS*WADDR_W-1:0]      act_rd_addr_flat,
    output reg  [ARRAY_ROWS-1:0]              act_valid,       // aligned with act_rd_data (1 cyc after rd_en)

    // Output scratchpad write ports (one per array column)
    input  wire [ARRAY_COLS-1:0]              valid_sum_out,   // from systolic_array, drives capture directly
    output wire [ARRAY_COLS-1:0]              out_wr_en,       // == valid_sum_out (bounded), fires the SAME cycle as out_wr_addr_flat
    output wire [ARRAY_COLS*WADDR_W-1:0]      out_wr_addr_flat // MUST be combinational, in lockstep with out_wr_en -
                                                                 // a registered address here would lag the (combinational)
                                                                 // enable by a cycle and silently corrupt every 2nd+ write
                                                                 // (this was an actual bug found during simulation: see git history)
);
    integer r, c;

    reg [$clog2(ARRAY_ROWS+WAVES+2)-1:0] stream_cyc;
    reg [WADDR_W-1:0] out_cnt [0:ARRAY_COLS-1];

    genvar gwe;
    wire [ARRAY_COLS-1:0] out_wr_en_bound;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat_comb;
    generate
        for (gwe = 0; gwe < ARRAY_COLS; gwe = gwe + 1) begin : g_owe
            assign out_wr_en_bound[gwe] = valid_sum_out[gwe] && (out_cnt[gwe] < WAVES);
            assign out_wr_addr_flat_comb[gwe*WADDR_W +: WADDR_W] = out_cnt[gwe];
        end
    endgenerate
    assign out_wr_en = out_wr_en_bound;
    assign out_wr_addr_flat = out_wr_addr_flat_comb;

    always @(posedge clk) begin
        if (!reset_n) begin
            stream_busy      <= 1'b0;
            compute_done     <= 1'b0;
            stream_cyc       <= 0;
            act_rd_en        <= {ARRAY_ROWS{1'b0}};
            act_rd_addr_flat <= {(ARRAY_ROWS*WADDR_W){1'b0}};
            act_valid        <= {ARRAY_ROWS{1'b0}};
            for (c = 0; c < ARRAY_COLS; c = c + 1)
                out_cnt[c] <= {WADDR_W{1'b0}};
        end else begin
            compute_done <= 1'b0;

            // ---- Kick off a new streaming pass ----
            if (stream_start) begin
                stream_busy <= 1'b1;
                stream_cyc  <= 0;
                for (c = 0; c < ARRAY_COLS; c = c + 1)
                    out_cnt[c] <= {WADDR_W{1'b0}};
            end else if (stream_busy) begin
                // Row r is active (has a real element to present) while
                // r <= stream_cyc < r + WAVES.
                for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
                    if (stream_cyc >= r && (stream_cyc - r) < WAVES) begin
                        act_rd_en[r] <= 1'b1;
                        act_rd_addr_flat[r*WADDR_W +: WADDR_W] <= stream_cyc - r;
                    end else begin
                        act_rd_en[r] <= 1'b0;
                    end
                end

                // Run ONE extra cycle past the last row's last real read so that
                // a clean "no row active" state gets computed and latched into
                // act_rd_en before streaming goes idle. Without this, act_rd_en
                // freezes at whatever nonzero pattern was active last (e.g. only
                // the final row's bit set) instead of returning to all-zero,
                // which would otherwise keep feeding a stale "valid" activation
                // into the array forever and never let valid_sum_out settle.
                if (stream_cyc == ARRAY_ROWS + WAVES - 1)
                    stream_busy <= 1'b0;
                else
                    stream_cyc <= stream_cyc + 1'b1;
            end

            // act_valid tracks act_rd_en delayed by 1 cycle (sram_2p read latency)
            act_valid <= act_rd_en;

            // ---- Output de-skew: capture wherever/whenever a column goes valid ----
            for (c = 0; c < ARRAY_COLS; c = c + 1) begin
                if (valid_sum_out[c] && out_cnt[c] < WAVES) begin
                    out_cnt[c] <= out_cnt[c] + 1'b1;
                    if (c == ARRAY_COLS-1 && out_cnt[c] == WAVES-1)
                        compute_done <= 1'b1;
                end
            end
        end
    end
endmodule
