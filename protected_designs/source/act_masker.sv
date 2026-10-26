//=====================================================================
// act_masker.sv -- array WEST-BOUNDARY activation masking stage
//
//   act_mask_rng : xorshift64 mask generator (non-cryptographic; swap
//                  for a TRNG/CSPRNG in a real deployment)
//   act_splitter : plaintext INT8 activation -> two additive shares
//                    a0 = mask_en ? r : 0
//                    a1 = sext(A) - a0          (mod 2^SHARE_W)
//   act_masker   : one rng + splitter per ROW. A fresh mask is drawn on
//                  every `advance` pulse (tie to 1 to mask every cycle,
//                  or to valid_act_in) so each streamed activation gets
//                  an independent mask. Row seeds are decorrelated with
//                  SplitMix64 of (SEED, row) so neighbouring rows never
//                  receive related masks.
//
// mask_en = 0 is the POSITIVE CONTROL: a0 = 0, a1 = A, i.e. the masked
// datapath degenerates to the unmasked function.
//
// Keep these modules OUTSIDE the dumped array scope (rule R4).
// Residual: the plaintext activation is present at the splitter input
// and the subtractor borrow chain is a joint function of A and r.
//=====================================================================
module act_mask_rng #(
    parameter W = 32,
    parameter [63:0] SEED = 64'd1
) (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         advance,
    output wire [W-1:0] r
);
    localparam [63:0] S0 = (SEED == 64'd0) ? 64'h9E3779B97F4A7C15 : SEED;
    reg [63:0] st;
    wire [63:0] x1 = st ^ (st << 13);
    wire [63:0] x2 = x1 ^ (x1 >> 7);
    wire [63:0] x3 = x2 ^ (x2 << 17);

    always @(posedge clk) begin
        if (!reset_n)     st <= S0;
        else if (advance) st <= x3;
    end
    assign r = st[W-1:0];
endmodule

module act_splitter #(
    parameter N       = 8,
    parameter SHARE_W = 32,
    parameter ROWS    = 1
) (
    input  wire                     mask_en,
    input  wire [ROWS*N-1:0]        act_flat,
    input  wire [ROWS*SHARE_W-1:0]  r_flat,
    output wire [ROWS*SHARE_W-1:0]  act0_flat,
    output wire [ROWS*SHARE_W-1:0]  act1_flat
);
    genvar i;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : g_row
            wire signed [N-1:0] a  = act_flat[i*N +: N];
            wire [SHARE_W-1:0]  ae = {{(SHARE_W-N){a[N-1]}}, a};
            wire [SHARE_W-1:0]  s0 = mask_en ? r_flat[i*SHARE_W +: SHARE_W]
                                             : {SHARE_W{1'b0}};
            assign act0_flat[i*SHARE_W +: SHARE_W] = s0;
            assign act1_flat[i*SHARE_W +: SHARE_W] = ae - s0;
        end
    endgenerate
endmodule

module act_masker #(
    parameter N       = 8,
    parameter SHARE_W = 32,
    parameter ROWS    = 5,
    parameter [63:0] SEED = 64'd1
) (
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     advance,
    input  wire                     mask_en,
    input  wire [ROWS*N-1:0]        act_flat,
    output wire [ROWS*SHARE_W-1:0]  act0_flat,
    output wire [ROWS*SHARE_W-1:0]  act1_flat
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

    wire [ROWS*SHARE_W-1:0] r_flat;
    genvar i;
    generate
        for (i = 0; i < ROWS; i = i + 1) begin : g_rng
            localparam [63:0] ROW_SEED = splitmix64(SEED ^ splitmix64(i + 1));
            act_mask_rng #(.W(SHARE_W), .SEED(ROW_SEED)) u_rng (
                .clk(clk), .reset_n(reset_n), .advance(advance),
                .r(r_flat[i*SHARE_W +: SHARE_W]));
        end
    endgenerate

    act_splitter #(.N(N), .SHARE_W(SHARE_W), .ROWS(ROWS)) u_split (
        .mask_en(mask_en), .act_flat(act_flat), .r_flat(r_flat),
        .act0_flat(act0_flat), .act1_flat(act1_flat));
endmodule
