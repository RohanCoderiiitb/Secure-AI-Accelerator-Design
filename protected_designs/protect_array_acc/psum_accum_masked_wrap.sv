//=====================================================================
// psum_accum_masked_wrap.sv -- DROP-IN replacement for psum_accum with a
// masked accumulator, for designs whose ARRAY IS NOT MASKED.
//
// Same ports/parameters as the baseline psum_accum (partial_sum_accumulators.sv):
//   plaintext psum_in  ->  [split into 2 shares, fresh mask per valid beat]
//                      ->  psum_accum_masked (mem0/mem1 lanes, acc0/acc1)
//                      ->  [recombine]  ->  plaintext psum_out
// Cycle behaviour (valid_out, ovf, psum_out timing) is identical to the baseline.
//
// WHAT THIS DOES AND DOES NOT PROTECT: the accumulator memory, its read/write
// path and its adders only ever hold shares. But the plaintext partial sum is
// present at this module's input (the split: share1 = psum - mask) and again
// at its output (the recombination), every beat, so those nets still carry
// the weight-dependent value. Expect only a partial reduction unless the array
// that feeds it is also in shares (then use psum_accum_masked directly).
//
// Needs: psum_accum_masked.sv, mask_rng.sv.   SHARE_W is fixed to ACCW.
//=====================================================================
module psum_accum_masked_wrap #(
    parameter N         = 8,
    parameter ACCW      = 32,
    parameter COLS      = 5,
    parameter DEPTH     = 32,
    parameter AW        = 6,
    parameter ROWS      = 5,            // array rows summed into one column psum (range check)
    parameter MAX_TILES = 64,           // max tiles accumulated per address (range check)
    parameter [63:0] SEED = 64'd1
)(
    input  wire                      clk,
    input  wire                      reset_n,
    input  wire                      tile_start,
    input  wire                      first_tile,
    input  wire                      last_tile,
    input  wire [COLS-1:0]           valid_in,
    input  wire [COLS*ACCW-1:0]      psum_in,
    output wire [COLS*ACCW-1:0]      psum_out,
    output wire [COLS-1:0]           valid_out,
    output wire [COLS-1:0]           ovf
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

    wire [COLS*ACCW-1:0] s0, s1, a0, a1;

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_col
            localparam [63:0] COL_SEED = splitmix64(SEED ^ splitmix64(c + 500));
            wire [ACCW-1:0] r;
            // one fresh mask per VALID beat of this column (state advances on the beat)
            mask_rng #(.W(ACCW), .SEED(COL_SEED)) u_rng (
                .clk(clk), .reset_n(reset_n), .advance(valid_in[c]), .r(r));
            assign s0[c*ACCW +: ACCW] = r;
            assign s1[c*ACCW +: ACCW] = psum_in[c*ACCW +: ACCW] - r;
            assign psum_out[c*ACCW +: ACCW] = a0[c*ACCW +: ACCW] + a1[c*ACCW +: ACCW];   // recombine
        end
    endgenerate

    psum_accum_masked #(.N(N), .SHARE_W(ACCW), .COLS(COLS), .DEPTH(DEPTH), .AW(AW),
                        .ROWS(ROWS), .MAX_TILES(MAX_TILES)) u_acc (
        .clk(clk), .reset_n(reset_n), .tile_start(tile_start),
        .first_tile(first_tile), .last_tile(last_tile), .valid_in(valid_in),
        .psum0_in(s0), .psum1_in(s1), .psum0_out(a0), .psum1_out(a1),
        .valid_out(valid_out), .ovf(ovf));
endmodule
