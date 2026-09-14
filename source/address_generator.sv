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

    output reg  [ARRAY_ROWS-1:0]              act_rd_en,
    output reg  [ARRAY_ROWS*WADDR_W-1:0]      act_rd_addr_flat,
    output reg  [ARRAY_ROWS-1:0]              act_valid,       // aligned with act_rd_data (1 cyc after rd_en)

    input  wire [ARRAY_COLS-1:0]              valid_sum_out,   // from systolic_array, drives capture directly
    output wire [ARRAY_COLS-1:0]              out_wr_en,       // == valid_sum_out (bounded), fires the SAME cycle as out_wr_addr_flat
    output wire [ARRAY_COLS*WADDR_W-1:0]      out_wr_addr_flat // MUST be combinational, in lockstep with out_wr_en -
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

            if (stream_start) begin
                stream_busy <= 1'b1;
                stream_cyc  <= 0;
                for (c = 0; c < ARRAY_COLS; c = c + 1)
                    out_cnt[c] <= {WADDR_W{1'b0}};
            end else if (stream_busy) begin
                // Row r is active while r <= stream_cyc < r + WAVES.
                for (r = 0; r < ARRAY_ROWS; r = r + 1) begin
                    if (stream_cyc >= r && (stream_cyc - r) < WAVES) begin
                        act_rd_en[r] <= 1'b1;
                        act_rd_addr_flat[r*WADDR_W +: WADDR_W] <= stream_cyc - r;
                    end else begin
                        act_rd_en[r] <= 1'b0;
                    end
                end

                if (stream_cyc == ARRAY_ROWS + WAVES - 1)
                    stream_busy <= 1'b0;
                else
                    stream_cyc <= stream_cyc + 1'b1;
            end

            // act_valid tracks act_rd_en delayed by 1 cycle (
            act_valid <= act_rd_en;

            // Output de-skew
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
