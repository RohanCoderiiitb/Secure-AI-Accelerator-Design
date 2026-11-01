//=====================================================================
// activation_masked.sv -- exact masked equivalent of activation_unit
// x arrives as BOOLEAN shares; mode, clamp_high, leaky_shift are PUBLIC.
//   PASS  : y = x
//   RELU  : y_i = x_i & ~s                       (s = sign share-pair)
//   CLIP  : y = s ? 0 : (x > clamp ? clamp : x)  (masked comparator + 2 muxes)
//   LEAKY : y = x ^ (s & (x ^ (x >>> k)))        (share-wise shift is exact)
// All four paths are built and aligned; the PUBLIC mode selects one at the
// end (selection by a public signal does not combine shares).
// Latency act_lat(N) = gt_lat(N) + 3 register stages.
//=====================================================================
module activation_masked #(
    parameter N  = 8,
    parameter RB = masked_pkg::act_rnd(N)
) (
    input  wire                clk,
    input  wire                reset_n,
    input  wire [1:0]          mode,
    input  wire                valid_in,
    input  wire [N-1:0]        x0, x1,
    input  wire [N-1:0]        clamp_high,
    input  wire [2:0]          leaky_shift,
    input  wire [RB-1:0]       rnd,
    output wire                valid_out,
    output reg  [N-1:0]        y0, y1
);
    localparam LG   = masked_pkg::gt_lat(N);
    localparam GRB  = masked_pkg::gt_rnd(N);
    localparam O_CM = GRB;              // clip: gt ? c : x      (N)
    localparam O_CR = GRB + N;          // clip: relu after clip (N)
    localparam O_R  = GRB + 2*N;        // relu path             (N)
    localparam O_L  = GRB + 3*N;        // leaky path            (N)
    localparam TE   = LG + 2;           // alignment time of all paths (before out reg)

    wire sg0 = x0[N-1], sg1 = x1[N-1];
    wire [N-1:0] S0 = {N{sg0}}, S1 = {N{sg1}};          // replicated sign shares
    wire [N-1:0] nS0 = ~S0,     nS1 = S1;                // ~sign: invert one share

    // ---- pass ----
    wire [N-1:0] pa0, pa1;
    delay_line #(.W(N), .D(TE)) u_pa0 (.clk(clk), .d(x0), .q(pa0));
    delay_line #(.W(N), .D(TE)) u_pa1 (.clk(clk), .d(x1), .q(pa1));

    // ---- relu ----
    wire [N-1:0] rz0, rz1, rr0, rr1;
    dom_and #(.W(N)) u_relu (.clk(clk), .x0(x0), .x1(x1), .y0(nS0), .y1(nS1),
                             .r(rnd[O_R +: N]), .z0(rz0), .z1(rz1));
    delay_line #(.W(N), .D(TE-1)) u_rr0 (.clk(clk), .d(rz0), .q(rr0));
    delay_line #(.W(N), .D(TE-1)) u_rr1 (.clk(clk), .d(rz1), .q(rr1));

    // ---- leaky ----
    wire signed [N-1:0] xs0 = x0, xs1 = x1;
    wire [N-1:0] k0 = xs0 >>> leaky_shift;
    wire [N-1:0] k1 = xs1 >>> leaky_shift;
    wire [N-1:0] lz0, lz1, lx0, lx1, lr0, lr1;
    dom_and #(.W(N)) u_leak (.clk(clk), .x0(S0), .x1(S1), .y0(x0 ^ k0), .y1(x1 ^ k1),
                             .r(rnd[O_L +: N]), .z0(lz0), .z1(lz1));
    delay_line #(.W(N), .D(1)) u_lx0 (.clk(clk), .d(x0), .q(lx0));
    delay_line #(.W(N), .D(1)) u_lx1 (.clk(clk), .d(x1), .q(lx1));
    delay_line #(.W(N), .D(TE-1)) u_lr0 (.clk(clk), .d(lx0 ^ lz0), .q(lr0));
    delay_line #(.W(N), .D(TE-1)) u_lr1 (.clk(clk), .d(lx1 ^ lz1), .q(lr1));

    // ---- relu-clip ----
    wire g0, g1;
    masked_gt #(.N(N)) u_gt (.clk(clk), .a0(x0), .a1(x1), .b0(clamp_high), .b1({N{1'b0}}),
                             .rnd(rnd[0 +: GRB]), .gt0(g0), .gt1(g1));
    wire [N-1:0] xg0, xg1, cg;                           // x and clamp delayed to the gt output
    delay_line #(.W(N), .D(LG)) u_xg0 (.clk(clk), .d(x0), .q(xg0));
    delay_line #(.W(N), .D(LG)) u_xg1 (.clk(clk), .d(x1), .q(xg1));
    delay_line #(.W(N), .D(LG)) u_cg  (.clk(clk), .d(clamp_high), .q(cg));
    wire [N-1:0] cz0, cz1;
    dom_and #(.W(N)) u_cmux (.clk(clk), .x0({N{g0}}), .x1({N{g1}}), .y0(xg0 ^ cg), .y1(xg1),
                             .r(rnd[O_CM +: N]), .z0(cz0), .z1(cz1));
    wire [N-1:0] xm0, xm1, sm0, sm1;                     // x and sign aligned to the mux output (LG+1)
    delay_line #(.W(N), .D(1)) u_xm0 (.clk(clk), .d(xg0), .q(xm0));
    delay_line #(.W(N), .D(1)) u_xm1 (.clk(clk), .d(xg1), .q(xm1));
    delay_line #(.W(N), .D(LG+1)) u_sm0 (.clk(clk), .d(nS0), .q(sm0));
    delay_line #(.W(N), .D(LG+1)) u_sm1 (.clk(clk), .d(nS1), .q(sm1));
    wire [N-1:0] mm0 = xm0 ^ cz0;                        // gt ? c : x
    wire [N-1:0] mm1 = xm1 ^ cz1;
    wire [N-1:0] cr0, cr1;
    dom_and #(.W(N)) u_crelu (.clk(clk), .x0(mm0), .x1(mm1), .y0(sm0), .y1(sm1),
                              .r(rnd[O_CR +: N]), .z0(cr0), .z1(cr1));

    // ---- public mode select, then output register ----
    wire [1:0] mode_e;
    delay_line #(.W(2), .D(TE)) u_mode (.clk(clk), .d(mode), .q(mode_e));
    always @(posedge clk) begin
        case (mode_e)
            2'd1:    begin y0 <= rr0; y1 <= rr1; end
            2'd2:    begin y0 <= cr0; y1 <= cr1; end
            2'd3:    begin y0 <= lr0; y1 <= lr1; end
            default: begin y0 <= pa0; y1 <= pa1; end
        endcase
    end
    delay_line #(.W(1), .D(TE + 1)) u_v (.clk(clk), .d(valid_in), .q(valid_out));
endmodule
