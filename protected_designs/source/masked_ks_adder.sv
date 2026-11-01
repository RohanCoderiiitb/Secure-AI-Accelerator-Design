//=====================================================================
// masked_ks_adder.sv -- Boolean-masked Kogge-Stone adder, K bits
//   (s0 ^ s1) == ((x0 ^ x1) + (y0 ^ y1)) mod 2^K
// Fully pipelined (a new operand pair every cycle), latency ks_lat(K)
// = 1 + ceil(log2 K) register stages; all non-linear steps are DOM-AND.
//   g = x & y (DOM-AND), p = x ^ y (share-wise)
//   per layer (distance d): G_i ^= P_i & G_{i-d} (i >= d),  P_i = P_i & P_{i-d} (i >= 2d)
//   carry into bit i = G_{i-1}, sum = p ^ (G << 1)
// G is combined with XOR (not OR): with p = x ^ y the generate and propagate
// of any group are mutually exclusive.
// Used as the A2B converter by feeding x = (A0, 0), y = (0, A1).
//=====================================================================
module masked_ks_adder #(
    parameter K  = 32,
    parameter RB = masked_pkg::ks_rnd(K)
) (
    input  wire          clk,
    input  wire [K-1:0]  x0, x1, y0, y1,
    input  wire [RB-1:0] rnd,
    output wire [K-1:0]  s0, s1
);
    localparam L = masked_pkg::clog2i(K);

    wire [K-1:0] p0 = x0 ^ y0;
    wire [K-1:0] p1 = x1 ^ y1;

    wire [K-1:0] G0 [0:L];
    wire [K-1:0] G1 [0:L];
    wire [K-1:0] P0 [0:L];
    wire [K-1:0] P1 [0:L];

    // init: g = x & y,  P[0] = p delayed one cycle
    dom_and #(.W(K)) u_g (.clk(clk), .x0(x0), .x1(x1), .y0(y0), .y1(y1),
                          .r(rnd[K-1:0]), .z0(G0[0]), .z1(G1[0]));
    delay_line #(.W(K), .D(1)) u_p0d (.clk(clk), .d(p0), .q(P0[0]));
    delay_line #(.W(K), .D(1)) u_p1d (.clk(clk), .d(p1), .q(P1[0]));

    genvar j;
    generate
        for (j = 0; j < L; j = j + 1) begin : g_layer
            localparam d    = 1 << j;
            localparam wG   = masked_pkg::ks_wG(K, j);
            localparam wP   = masked_pkg::ks_wP(K, j);
            localparam base = masked_pkg::ks_base(K, j);

            wire [wG-1:0] zg0, zg1;
            dom_and #(.W(wG)) u_ag (
                .clk(clk),
                .x0(P0[j][K-1:d]),    .x1(P1[j][K-1:d]),
                .y0(G0[j][wG-1:0]),   .y1(G1[j][wG-1:0]),
                .r(rnd[base +: wG]),
                .z0(zg0), .z1(zg1));

            wire [K-1:0] Gd0, Gd1;                        // G delayed one cycle (alignment)
            delay_line #(.W(K), .D(1)) u_gd0 (.clk(clk), .d(G0[j]), .q(Gd0));
            delay_line #(.W(K), .D(1)) u_gd1 (.clk(clk), .d(G1[j]), .q(Gd1));
            assign G0[j+1] = {Gd0[K-1:d] ^ zg0, Gd0[d-1:0]};
            assign G1[j+1] = {Gd1[K-1:d] ^ zg1, Gd1[d-1:0]};

            if (wP > 0) begin : g_p
                wire [wP-1:0] zp0, zp1;
                dom_and #(.W(wP)) u_ap (
                    .clk(clk),
                    .x0(P0[j][K-1:2*d]),    .x1(P1[j][K-1:2*d]),
                    .y0(P0[j][K-1-d:d]),    .y1(P1[j][K-1-d:d]),
                    .r(rnd[base + wG +: wP]),
                    .z0(zp0), .z1(zp1));
                assign P0[j+1] = {zp0, {(2*d){1'b0}}};
                assign P1[j+1] = {zp1, {(2*d){1'b0}}};
            end else begin : g_nop
                assign P0[j+1] = {K{1'b0}};
                assign P1[j+1] = {K{1'b0}};
            end
        end
    endgenerate

    wire [K-1:0] pf0, pf1;                                // p delayed 1 + L cycles
    delay_line #(.W(K), .D(L+1)) u_pf0 (.clk(clk), .d(p0), .q(pf0));
    delay_line #(.W(K), .D(L+1)) u_pf1 (.clk(clk), .d(p1), .q(pf1));

    assign s0 = pf0 ^ {G0[L][K-2:0], 1'b0};
    assign s1 = pf1 ^ {G1[L][K-2:0], 1'b0};
endmodule
