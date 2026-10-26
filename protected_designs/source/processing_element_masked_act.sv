//=====================================================================
// processing_element_masked_act.sv -- weight-stationary PE, 2-share
// ACTIVATIONS, plaintext weights
//
// Baseline behaviour (processing_element) is preserved cycle for cycle;
// the activation/psum datapath is duplicated per share, all arithmetic
// modulo 2^SHARE_W:
//
//   wt_reg        <= wt_in                          on wt_load
//   act{0,1}_out  <= act{0,1}_in
//   psum{0,1}_out <= psum{0,1}_in + wt_reg * act{k}_in
//   (act0 + act1) mod 2^SHARE_W == sext(activation)
//   (psum0_out + psum1_out) mod 2^SHARE_W == baseline psum_out
//
// The weight is public in this threat model and is forwarded unchanged
// (wt_out). The activation shares are forwarded eastwards together.
//
// The two multiplier instances each see ONE activation share only, so no
// net inside either multiplier is a function of the plaintext activation.
// The shares recombine only through the linear psum accumulation, never
// inside a combinational cone.
//
// Needs share_multiplier (masked_wt_multiplier.sv). SHARE_W must satisfy
// SHARE_W >= 18 for a 5-row column; the default 32 equals ACCW.
//=====================================================================
module processing_element_masked_act #(
    parameter N        = 8,
    parameter SHARE_W  = 32
) (
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     wt_load,
    input  wire signed [N-1:0]      wt_in,        // plaintext weight, from the north
    input  wire                     valid_in,
    input  wire [SHARE_W-1:0]       act0_in,      // from the west, share 0
    input  wire [SHARE_W-1:0]       act1_in,      // from the west, share 1
    input  wire [SHARE_W-1:0]       psum0_in,     // from the north, share 0
    input  wire [SHARE_W-1:0]       psum1_in,     // from the north, share 1
    output reg                      valid_out,
    output wire signed [N-1:0]      wt_out,       // southwards
    output reg  [SHARE_W-1:0]       act0_out,     // eastwards, share 0
    output reg  [SHARE_W-1:0]       act1_out,     // eastwards, share 1
    output reg  [SHARE_W-1:0]       psum0_out,    // southwards, share 0
    output reg  [SHARE_W-1:0]       psum1_out     // southwards, share 1
);
    reg signed [N-1:0] wt_reg;
    assign wt_out = wt_reg;

    wire [SHARE_W-1:0] prod0, prod1;

    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SHARE_W)) u_mul0 (.a(wt_reg), .ws(act0_in), .p(prod0));
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SHARE_W)) u_mul1 (.a(wt_reg), .ws(act1_in), .p(prod1));

    always @(posedge clk) begin
        if (!reset_n) begin
            valid_out <= 1'b0;
            wt_reg    <= {N{1'b0}};
            act0_out  <= {SHARE_W{1'b0}};
            act1_out  <= {SHARE_W{1'b0}};
            psum0_out <= {SHARE_W{1'b0}};
            psum1_out <= {SHARE_W{1'b0}};
        end else begin
            if (wt_load) wt_reg <= wt_in;
            act0_out  <= act0_in;
            act1_out  <= act1_in;
            psum0_out <= psum0_in + prod0;
            psum1_out <= psum1_in + prod1;
            valid_out <= valid_in;
        end
    end
endmodule
