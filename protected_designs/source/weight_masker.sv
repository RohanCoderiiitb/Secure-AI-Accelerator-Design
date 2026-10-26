//=====================================================================
// weight_masker.sv -- array NORTH-BOUNDARY masking stage (COLS columns)
//
// One mask_rng + weight_splitter per column. Weights shift down each
// column on every wt_load pulse, so a fresh mask is drawn per injected
// weight and both shares then travel together; masks are therefore
// independent per final PE location.
//
// SEEDS. Neighbouring columns must NOT get related masks: with seeds
// SEED + k*col the first masks of columns are an arithmetic progression
// (r_c = r_0 + c*k), and w1_c - w1_0 = (W_c - W_0) - c*k would reveal the
// weight difference. Each column seed is therefore decorrelated with
// SplitMix64 of (SEED, col).
//
// Keep this module OUTSIDE the dumped array scope (rule R4 / decision 6).
//=====================================================================
module weight_masker #(
    parameter N       = 8,
    parameter SHARE_W = 32,
    parameter COLS    = 5,
    parameter [63:0] SEED = 64'd1
) (
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     wt_load,
    input  wire                     mask_en,
    input  wire [COLS*N-1:0]        wt_flat,
    output wire [COLS*SHARE_W-1:0]  wt0_flat,
    output wire [COLS*SHARE_W-1:0]  wt1_flat
);
    function [63:0] splitmix64(input [63:0] x);
        reg [63:0] z;
        begin
            z = x + 64'h9E3779B97F4A7C15;
            z = (z ^ (z >> 30)) * 64'hBF58476D1CE4E5B9;
            z = (z ^ (z >> 27)) * 64'h94D049BB133111EB;
            splitmix64 = z ^ (z >> 31);
        end
    endfunction

    wire [COLS*SHARE_W-1:0] r_flat;
    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_rng
            localparam [63:0] COL_SEED = splitmix64(SEED ^ splitmix64(c + 1));
            mask_rng #(.W(SHARE_W), .SEED(COL_SEED)) u_rng (
                .clk(clk), .reset_n(reset_n), .advance(wt_load),
                .r(r_flat[c*SHARE_W +: SHARE_W]));
        end
    endgenerate

    weight_splitter #(.N(N), .SHARE_W(SHARE_W), .COLS(COLS)) u_split (
        .mask_en(mask_en), .wt_flat(wt_flat), .r_flat(r_flat),
        .wt0_flat(wt0_flat), .wt1_flat(wt1_flat));
endmodule
