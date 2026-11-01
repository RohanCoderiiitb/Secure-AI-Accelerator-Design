//=====================================================================
// mask_prng_bus.sv -- SIMULATION-ONLY wide fresh-randomness source
// W random bits per clock from ceil(W/64) independent xorshift64* streams
// (distinct SplitMix64-derived seeds, advanced every cycle). Replace with
// a TRNG + conditioner / a masked-gadget-quality PRNG for silicon.
//=====================================================================
module mask_prng_bus #(
    parameter W = 64,
    parameter [63:0] SEED = 64'd1
) (
    input  wire         clk,
    input  wire         reset_n,
    output wire [W-1:0] rnd
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

    localparam NI = (W + 63) / 64;
    wire [NI*64-1:0] flat;
    genvar i;
    generate
        for (i = 0; i < NI; i = i + 1) begin : g_rng
            localparam [63:0] S = splitmix64(SEED ^ splitmix64(i + 1000));
            mask_rng #(.W(64), .SEED(S)) u_rng (.clk(clk), .reset_n(reset_n), .advance(1'b1),
                                                .r(flat[i*64 +: 64]));
        end
    endgenerate
    assign rnd = flat[W-1:0];
endmodule
