// Baugh-Wooley multiplier with masked activations
// Arithmetic Masking

module masked_act_multiplier #(
    parameter N  = 8,
    parameter SW = 2*N
) (
    input  wire          clk,
    input  wire          reset_n,

    // plain weight
    input  wire          w_load,
    input  wire [N-1:0]  w_in,

    // activation shares: a0 + a1 = sext(a) mod 2^SW
    input  wire [SW-1:0] a0,
    input  wire [SW-1:0] a1,

    output wire [SW-1:0] p0,            // p0 + p1 = a*w (mod 2^SW)
    output wire [SW-1:0] p1
);
    reg [N-1:0] w_reg;

    always @(posedge clk) begin
        if (!reset_n)    w_reg <= {N{1'b0}};
        else if (w_load) w_reg <= w_in;
    end

    // one share multiplier per domain; never combined inside the DUT
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SW)) u_dom0 (.a(w_reg), .ws(a0), .p(p0));
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SW)) u_dom1 (.a(w_reg), .ws(a1), .p(p1));
endmodule
