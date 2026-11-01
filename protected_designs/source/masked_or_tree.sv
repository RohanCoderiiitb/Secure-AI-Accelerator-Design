//=====================================================================
// masked_or_tree.sv -- OR of NB bit-shared bits (a|b = a ^ b ^ (a&b))
// Binary tree, one DOM-AND layer per level, odd leftover bit passes
// through a delay register. Latency or_lat(NB) = ceil(log2 NB), NB-1 gates.
//=====================================================================
module masked_or_tree #(
    parameter NB = 56,
    parameter RB = masked_pkg::or_rnd(NB)
) (
    input  wire          clk,
    input  wire [NB-1:0] t0, t1,
    input  wire [RB-1:0] rnd,
    output wire          o0, o1
);
    localparam L = masked_pkg::or_lat(NB);
    wire [NB-1:0] C0 [0:L];
    wire [NB-1:0] C1 [0:L];
    assign C0[0] = t0;
    assign C1[0] = t1;

    genvar l;
    generate
        for (l = 0; l < L; l = l + 1) begin : g_lvl
            localparam w   = masked_pkg::or_w(NB, l);
            localparam h   = w / 2;
            localparam odd = w % 2;
            localparam off = masked_pkg::or_off(NB, l);

            wire [h-1:0] x0 = C0[l][h-1:0];
            wire [h-1:0] x1 = C1[l][h-1:0];
            wire [h-1:0] y0 = C0[l][2*h-1:h];
            wire [h-1:0] y1 = C1[l][2*h-1:h];
            wire [h-1:0] z0, z1, xd0, xd1, yd0, yd1;
            dom_and #(.W(h)) u_and (.clk(clk), .x0(x0), .x1(x1), .y0(y0), .y1(y1),
                                    .r(rnd[off +: h]), .z0(z0), .z1(z1));
            delay_line #(.W(h), .D(1)) u_x0 (.clk(clk), .d(x0), .q(xd0));
            delay_line #(.W(h), .D(1)) u_x1 (.clk(clk), .d(x1), .q(xd1));
            delay_line #(.W(h), .D(1)) u_y0 (.clk(clk), .d(y0), .q(yd0));
            delay_line #(.W(h), .D(1)) u_y1 (.clk(clk), .d(y1), .q(yd1));
            wire [h-1:0] res0 = xd0 ^ yd0 ^ z0;
            wire [h-1:0] res1 = xd1 ^ yd1 ^ z1;

            if (odd) begin : g_odd
                wire l0, l1;
                delay_line #(.W(1), .D(1)) u_l0 (.clk(clk), .d(C0[l][w-1]), .q(l0));
                delay_line #(.W(1), .D(1)) u_l1 (.clk(clk), .d(C1[l][w-1]), .q(l1));
                assign C0[l+1] = {{(NB-h-1){1'b0}}, l0, res0};
                assign C1[l+1] = {{(NB-h-1){1'b0}}, l1, res1};
            end else begin : g_even
                assign C0[l+1] = {{(NB-h){1'b0}}, res0};
                assign C1[l+1] = {{(NB-h){1'b0}}, res1};
            end
        end
    endgenerate

    assign o0 = C0[L][0];
    assign o1 = C1[L][0];
endmodule
