//=====================================================================
// masked_gt.sv -- (a > b) for N-bit SIGNED Boolean-shared operands
//   gt = sign( b - a )  computed as b + ~a + 1 in N+1 bits (no overflow:
//   8-bit differences fit 9 bits) with a masked Kogge-Stone adder.
// The "+1" is folded in by appending a constant-1 LSB to both operands
// (1 + 1 = 0 carry 1): K = N + 2.  Latency gt_lat(N) = ks_lat(N+2).
// Public operands are passed as the sharing (c, 0).
//=====================================================================
module masked_gt #(
    parameter N  = 8,
    parameter RB = masked_pkg::gt_rnd(N)
) (
    input  wire          clk,
    input  wire [N-1:0]  a0, a1, b0, b1,
    input  wire [RB-1:0] rnd,
    output wire          gt0, gt1
);
    localparam K = N + 2;
    wire [N:0] ax0 = {a0[N-1], a0};          // per-share sign extension (XOR-linear, exact)
    wire [N:0] ax1 = {a1[N-1], a1};
    wire [N:0] bx0 = {b0[N-1], b0};
    wire [N:0] bx1 = {b1[N-1], b1};

    wire [K-1:0] X0 = {bx0, 1'b1};
    wire [K-1:0] X1 = {bx1, 1'b0};
    wire [K-1:0] Y0 = {~ax0, 1'b1};          // ~a: invert ONE share only
    wire [K-1:0] Y1 = {ax1, 1'b0};
    wire [K-1:0] s0, s1;

    masked_ks_adder #(.K(K)) u_add (.clk(clk), .x0(X0), .x1(X1), .y0(Y0), .y1(Y1),
                                    .rnd(rnd), .s0(s0), .s1(s1));
    assign gt0 = s0[K-1];
    assign gt1 = s1[K-1];
endmodule
