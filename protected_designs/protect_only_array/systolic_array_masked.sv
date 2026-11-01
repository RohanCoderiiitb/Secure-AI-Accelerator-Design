//=====================================================================
// systolic_array_masked.sv -- ROWS x COLS grid of processing_element_masked
//
// Same dataflow as systolic_array (weights shift down on wt_load,
// activations flow west->east, partial sums north->south, no input
// skew / output de-skew). Differences:
//   * weights enter as TWO share vectors (wt0_flat, wt1_flat) and shift
//     down together;
//   * partial sums travel as TWO share chains; the north inputs are
//     shares of 0 in a tile, the south outputs are shares of the column
//     sum:  (psum0_out + psum1_out) mod 2^SHARE_W == baseline psum_out.
// The PE instance is still named g_row[r].g_col[c].pe_inst so existing
// hierarchical probes and $dumpvars scopes keep working.
//=====================================================================
module systolic_array_masked #(
    parameter N       = 8,
    parameter SHARE_W = 32,
    parameter ROWS    = 5,
    parameter COLS    = 5
) (
    input  wire                      clk,
    input  wire                      reset_n,
    input  wire                      wt_load,
    input  wire [COLS*SHARE_W-1:0]   wt0_flat,
    input  wire [COLS*SHARE_W-1:0]   wt1_flat,
    input  wire [ROWS-1:0]           valid_act_in,
    input  wire [ROWS*N-1:0]         act_flat,
    input  wire [COLS*SHARE_W-1:0]   psum0_flat,
    input  wire [COLS*SHARE_W-1:0]   psum1_flat,
    output wire [COLS*SHARE_W-1:0]   psum0_out,
    output wire [COLS*SHARE_W-1:0]   psum1_out,
    output wire [COLS-1:0]           valid_sum_out,
    output wire [ROWS*N-1:0]         act_out,
    output wire [ROWS-1:0]           valid_act_out
);
    wire signed [N-1:0]  act  [0:ROWS-1][0:COLS];
    wire                 vld  [0:ROWS-1][0:COLS];
    wire [SHARE_W-1:0]   ps0  [0:ROWS][0:COLS-1];
    wire [SHARE_W-1:0]   ps1  [0:ROWS][0:COLS-1];
    wire [SHARE_W-1:0]   wt0  [0:ROWS][0:COLS-1];
    wire [SHARE_W-1:0]   wt1  [0:ROWS][0:COLS-1];

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_west
            assign act[r][0]        = act_flat[r*N +: N];
            assign vld[r][0]        = valid_act_in[r];
            assign act_out[r*N +: N]= act[r][COLS];
            assign valid_act_out[r] = vld[r][COLS];
        end
        for (c = 0; c < COLS; c = c + 1) begin : g_north
            assign wt0[0][c] = wt0_flat [c*SHARE_W +: SHARE_W];
            assign wt1[0][c] = wt1_flat [c*SHARE_W +: SHARE_W];
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
                wire [SHARE_W-1:0]   pe_wt0_out, pe_wt1_out;
                wire signed [N-1:0]  pe_act_out;
                wire [SHARE_W-1:0]   pe_ps0_out, pe_ps1_out;

                (* dont_touch = "yes" *)
                processing_element_masked #(.N(N), .SHARE_W(SHARE_W)) pe_inst (
                    .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
                    .wt0_in(wt0[r][c]), .wt1_in(wt1[r][c]),
                    .valid_in(vld[r][c]), .act_in(act[r][c]),
                    .psum0_in(ps0[r][c]), .psum1_in(ps1[r][c]),
                    .valid_out(pe_valid_out),
                    .wt0_out(pe_wt0_out), .wt1_out(pe_wt1_out),
                    .act_out(pe_act_out),
                    .psum0_out(pe_ps0_out), .psum1_out(pe_ps1_out));

                assign act[r][c+1]   = pe_act_out;
                assign vld[r][c+1]   = pe_valid_out;
                assign wt0[r+1][c]   = pe_wt0_out;
                assign wt1[r+1][c]   = pe_wt1_out;
                assign ps0[r+1][c]   = pe_ps0_out;
                assign ps1[r+1][c]   = pe_ps1_out;
            end
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_south_valid
            assign valid_sum_out[c] = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule
