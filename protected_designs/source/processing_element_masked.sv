//=====================================================================
// processing_element_masked.sv -- weight-stationary PE, 2-share weights
//
// Baseline behaviour (processing_element in processing_element.sv) is
// preserved cycle for cycle; only the weight/psum datapath is duplicated
// per share, all arithmetic modulo 2^SHARE_W:
//
//   wt{0,1}_reg   <= wt{0,1}_in                    on wt_load
//   psum{0,1}_out <= psum{0,1}_in + act * wt{k}_reg
//   (psum0_out + psum1_out) mod 2^SHARE_W == baseline psum_out
//
// The weight shares are forwarded (wt{0,1}_out) so they shift down the
// column together, as the baseline weight does. act_out / valid_out are
// unchanged: activations are public in this threat model.
//
// The two multiplier instances each see ONE share only, so no net inside
// either multiplier is a function of the plaintext weight. The shares
// recombine only through the linear psum accumulation, never inside a
// combinational cone.
//
// SHARE_W must satisfy SHARE_W >= 18 for a 5-row column (see
// golden/phase1_results.txt, experiment A); the default 32 equals ACCW.
//=====================================================================
module processing_element_masked #(
    parameter N        = 8,
    parameter SHARE_W  = 32
) (
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     wt_load,
    input  wire [SHARE_W-1:0]       wt0_in,
    input  wire [SHARE_W-1:0]       wt1_in,
    input  wire                     valid_in,
    input  wire signed [N-1:0]      act_in,       // from the west
    input  wire [SHARE_W-1:0]       psum0_in,     // from the north, share 0
    input  wire [SHARE_W-1:0]       psum1_in,     // from the north, share 1
    output reg                      valid_out,
    output wire [SHARE_W-1:0]       wt0_out,
    output wire [SHARE_W-1:0]       wt1_out,
    output reg  signed [N-1:0]      act_out,      // eastwards
    output reg  [SHARE_W-1:0]       psum0_out,    // southwards, share 0
    output reg  [SHARE_W-1:0]       psum1_out     // southwards, share 1
);
    reg [SHARE_W-1:0] wt0_reg, wt1_reg;
    assign wt0_out = wt0_reg;
    assign wt1_out = wt1_reg;

    wire [SHARE_W-1:0] prod0, prod1;

    share_multiplier #(.N(N), .SW(SHARE_W)) u_mul0 (.a(act_in), .ws(wt0_reg), .p(prod0));
    share_multiplier #(.N(N), .SW(SHARE_W)) u_mul1 (.a(act_in), .ws(wt1_reg), .p(prod1));


    always @(posedge clk) begin
        if (!reset_n) begin
            valid_out <= 1'b0;
            act_out   <= {N{1'b0}};
            wt0_reg   <= {SHARE_W{1'b0}};
            wt1_reg   <= {SHARE_W{1'b0}};
            psum0_out <= {SHARE_W{1'b0}};
            psum1_out <= {SHARE_W{1'b0}};
        end else begin
            if (wt_load) begin
                wt0_reg <= wt0_in;
                wt1_reg <= wt1_in;
            end
            act_out   <= act_in;
            psum0_out <= psum0_in + prod0;
            psum1_out <= psum1_in + prod1;
            valid_out <= valid_in;
        end
    end
endmodule
