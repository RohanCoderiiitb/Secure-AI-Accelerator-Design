//=====================================================================
// systolic_array_masked_act.sv -- ROWS x COLS grid of
// processing_element_masked_act (activations masked, weights plaintext)
//
// Same dataflow as systolic_array (weights shift down on wt_load,
// activations flow west->east, partial sums north->south, no input
// skew / output de-skew). Differences:
//   * activations enter as TWO share vectors (act0_flat, act1_flat) per
//     row and travel east together;
//   * partial sums travel as TWO share chains; the north inputs are
//     shares of 0 in a tile, the south outputs are shares of the column
//     sum:  (psum0_out + psum1_out) mod 2^SHARE_W == baseline psum_out.
//   * weights are plaintext, exactly as in the baseline.
// The PE instance is still named g_row[r].g_col[c].pe_inst.
//=====================================================================
module systolic_array_masked_act #(
    parameter N       = 8,
    parameter SHARE_W = 32,
    parameter ROWS    = 5,
    parameter COLS    = 5
) (
    input  wire                      clk,
    input  wire                      reset_n,
    input  wire                      wt_load,
    input  wire [COLS*N-1:0]         wt_flat,
    input  wire [ROWS-1:0]           valid_act_in,
    input  wire [ROWS*SHARE_W-1:0]   act0_flat,
    input  wire [ROWS*SHARE_W-1:0]   act1_flat,
    input  wire [COLS*SHARE_W-1:0]   psum0_flat,
    input  wire [COLS*SHARE_W-1:0]   psum1_flat,
    output wire [COLS*SHARE_W-1:0]   psum0_out,
    output wire [COLS*SHARE_W-1:0]   psum1_out,
    output wire [COLS-1:0]           valid_sum_out,
    output wire [ROWS*SHARE_W-1:0]   act0_out,
    output wire [ROWS*SHARE_W-1:0]   act1_out,
    output wire [ROWS-1:0]           valid_act_out
);
    wire [SHARE_W-1:0]   a0   [0:ROWS-1][0:COLS];
    wire [SHARE_W-1:0]   a1   [0:ROWS-1][0:COLS];
    wire                 vld  [0:ROWS-1][0:COLS];
    wire [SHARE_W-1:0]   ps0  [0:ROWS][0:COLS-1];
    wire [SHARE_W-1:0]   ps1  [0:ROWS][0:COLS-1];
    wire signed [N-1:0]  wt   [0:ROWS][0:COLS-1];

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_west
            assign a0[r][0]                    = act0_flat[r*SHARE_W +: SHARE_W];
            assign a1[r][0]                    = act1_flat[r*SHARE_W +: SHARE_W];
            assign vld[r][0]                   = valid_act_in[r];
            assign act0_out[r*SHARE_W +: SHARE_W] = a0[r][COLS];
            assign act1_out[r*SHARE_W +: SHARE_W] = a1[r][COLS];
            assign valid_act_out[r]            = vld[r][COLS];
        end
        for (c = 0; c < COLS; c = c + 1) begin : g_north
            assign wt[0][c]  = wt_flat[c*N +: N];
            assign ps0[0][c] = psum0_flat[c*SHARE_W +: SHARE_W];
            assign ps1[0][c] = psum1_flat[c*SHARE_W +: SHARE_W];
            assign psum0_out[c*SHARE_W +: SHARE_W] = ps0[ROWS][c];
            assign psum1_out[c*SHARE_W +: SHARE_W] = ps1[ROWS][c];
        end
    endgenerate

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                wire                 pe_valid_out;
                wire signed [N-1:0]  pe_wt_out;
                wire [SHARE_W-1:0]   pe_a0_out, pe_a1_out;
                wire [SHARE_W-1:0]   pe_ps0_out, pe_ps1_out;

                (* dont_touch = "yes" *)
                processing_element_masked_act #(.N(N), .SHARE_W(SHARE_W)) pe_inst (
                    .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
                    .wt_in(wt[r][c]), .valid_in(vld[r][c]),
                    .act0_in(a0[r][c]), .act1_in(a1[r][c]),
                    .psum0_in(ps0[r][c]), .psum1_in(ps1[r][c]),
                    .valid_out(pe_valid_out), .wt_out(pe_wt_out),
                    .act0_out(pe_a0_out), .act1_out(pe_a1_out),
                    .psum0_out(pe_ps0_out), .psum1_out(pe_ps1_out));

                assign a0[r][c+1]  = pe_a0_out;
                assign a1[r][c+1]  = pe_a1_out;
                assign vld[r][c+1] = pe_valid_out;
                assign wt[r+1][c]  = pe_wt_out;
                assign ps0[r+1][c] = pe_ps0_out;
                assign ps1[r+1][c] = pe_ps1_out;
            end
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_south_valid
            assign valid_sum_out[c] = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule
