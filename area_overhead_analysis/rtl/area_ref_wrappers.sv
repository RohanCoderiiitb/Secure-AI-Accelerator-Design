//=====================================================================
// area_ref_wrappers.sv -- thin wrapper used ONLY for the area analysis
//
//   bw_multiplier_wreg       : unprotected Baugh-Wooley multiplier plus the
//                              same stationary weight register that every
//                              masked multiplier carries (w_load / w_reg).
//                              This is the like-for-like baseline: the
//                              masked multipliers all register their weight
//                              (share), the bare baugh_wooley_multiplier is
//                              purely combinational.
//
// No functional change to any design under test; it only adds the logic
// the comparison would otherwise silently leave out.
//=====================================================================
module bw_multiplier_wreg #(
    parameter N = 8
) (
    input  wire           clk,
    input  wire           reset_n,
    input  wire           w_load,
    input  wire [N-1:0]   w_in,
    input  wire [N-1:0]   a,
    output wire [2*N-1:0] p
);
    reg [N-1:0] w_reg;

    always @(posedge clk) begin
        if (!reset_n)    w_reg <= {N{1'b0}};
        else if (w_load) w_reg <= w_in;
    end

    baugh_wooley_multiplier #(.N(N)) u_mul (.x(a), .y(w_reg), .p(p));
endmodule
