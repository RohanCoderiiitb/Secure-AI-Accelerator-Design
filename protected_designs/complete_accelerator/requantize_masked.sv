//=====================================================================
// requantize_masked.sv -- first-order masked TFLite requantizer (v2)
//
// Same function as requantize (source/requantization_block.sv):
//   q = clamp( ((acc + bias) * m0 + round) >>> shift , -128, 127 )
// acc arrives as two arithmetic shares  acc = x0 + x1 (mod 2^XW)
// (straight from the weight-masked array / masked psum accumulator);
// q and sat leave as two Boolean shares  q = q0 ^ q1, sat = sat0 ^ sat1.
// bias, m0, shift are public per-layer constants and must stay stable
// while values are in flight (as they do for a layer).
//
// Pipeline (DOM_REG = 1, 18 cycles, one new value every cycle)
//   IN    re-mask the shares into registered Boolean sharings         1
//   LIFT  masked carry tree: wrap carry c of x0 + x1                  6
//   B2A   carry -> arithmetic correction c*K, registered 2-step mux   2
//         (+ per-share bias / *m0 / +round, re-mask for the adder)
//   A2B   masked prefix adder (Boolean shares of Q)                   7
//         in parallel: "in range" test by carry-free zero detection
//   Z     in range = ~s_k & T                                         1
//   CLAMP q = sat_val ^ (inrange & (byte ^ sat_val))                  1
//
// What changed vs v1 (22 cycles)
//   * Saturation is found in PARALLEL with the adder: "bits >= k of the
//     sum are all zero" is checked straight from the adder's first-layer
//     generate/propagate signals (carry-free zero detection), so the
//     6-cycle AND tree that ran AFTER the adder is gone.
//   * The clamp needs one masked AND per bit (was two) and no byte refresh.
//   * The two places where v1 combined both shares of a secret in one
//     combinational cone (input re-masking, carry B2A mux) now go through
//     registers, so the design is glitch-robust where v1 was not.
//   * Narrow inputs are delayed instead of 52-bit products (fewer flops);
//     only the 10 propagate bits the output needs are carried to the end;
//     the last prefix level computes carries only.
//
// DOM_REG = 0: all masked AND layers combinational, 3-cycle latency;
//              first-order secure in the glitch-free RTL/toggle model only.
//
// Validity range (identical outputs to requantize):
//   |acc + bias| < 2^XW  and  shift <= RW-9   (same as v1)
//   Random bits per cycle and latency: msk_counts.vh
//=====================================================================
module requantize_masked (clk, reset_n, valid_in, x0_in, x1_in, bias_in, m0_in, shift_in,
                          rnd_in, valid_out, q0_out, q1_out, sat0_out, sat1_out);
    parameter N       = 8;
    parameter XW      = 18;
    parameter BW      = 32;           // bias width
    parameter MW      = 32;
    parameter SW      = 6;            // shift width
    parameter RW      = XW + MW + 2;  // internal ring width
    parameter DOM_REG = 1;

    `include "msk_counts.vh"

    localparam RND_W = mskf_rq_rnd(XW, RW);
    localparam LAT   = mskf_rq_lat(XW, RW, DOM_REG);
    localparam R     = DOM_REG ? 1 : 0;              // robustness register stage on/off
    localparam LIFT  = R ? 1 + $clog2(XW) : 0;       // carry-tree latency
    localparam LPFX  = R ? $clog2(RW) : 0;           // prefix-tree latency
    localparam LT    = R ? $clog2(RW - 1) : 0;       // zero-detect tree latency
    localparam RH    = RW - XW;                      // B2A masks live in bits >= XW
    localparam M     = RW - 1;                       // zero-detect terms (positions 1..RW-1)
    localparam HP    = (M + 1) / 2;                  // pair distance in the zero-detect tree

    // random-bus layout (fresh bits every cycle)
    localparam O_RA1 = 0;
    localparam O_RB1 = O_RA1 + XW;
    localparam O_ZL  = O_RB1 + XW;
    localparam O_R0  = O_ZL  + mskf_cout_z(XW);
    localparam O_R1  = O_R0  + RH;
    localparam O_RA2 = O_R1  + RH;
    localparam O_RB2 = O_RA2 + RW;
    localparam O_ZG  = O_RB2 + RW;
    localparam O_ZP  = O_ZG  + RW;
    localparam O_ZT  = O_ZP  + mskf_pfx_z(RW);
    localparam O_ZZ  = O_ZT  + mskf_and_z(M);
    localparam O_ZC  = O_ZZ  + 1;

    input  wire                   clk, reset_n, valid_in;
    input  wire [XW-1:0]          x0_in, x1_in;
    input  wire signed [BW-1:0]   bias_in;
    input  wire signed [MW-1:0]   m0_in;
    input  wire [SW-1:0]          shift_in;
    input  wire [RND_W-1:0]       rnd_in;
    output wire                   valid_out;
    output wire [N-1:0]           q0_out, q1_out;
    output wire                   sat0_out, sat1_out;

    localparam [RW-1:0] ONE   = {{(RW-1){1'b0}}, 1'b1};
    localparam [XW-1:0] HALF  = {1'b1, {(XW-1){1'b0}}};
    localparam [N-1:0]  QHI   = {1'b0, {(N-1){1'b1}}};      // 0x7F
    localparam [N-1:0]  QOFF  = {1'b1, {(N-1){1'b0}}};      // 0x80

    // ================= IN: registered Boolean re-masking =================
    wire [XW-1:0] x0p = x0_in + HALF;                       // offset share 0
    wire [XW-1:0] ra1 = rnd_in[O_RA1 +: XW];
    wire [XW-1:0] rb1 = rnd_in[O_RB1 +: XW];
    wire [XW-1:0] la0, la1, lb0, lb1;
    msk_pipe #(.W(4*XW), .D(1)) u_in (.clk(clk),
        .d({x0p ^ ra1, ra1, rb1, x1_in ^ rb1}), .q({la0, la1, lb0, lb1}));

    // arithmetic shares travel narrow (XW bits) to the B2A stage
    wire [XW-1:0] x0d, x1d;
    msk_pipe #(.W(2*XW), .D(1 + LIFT + R)) u_x (.clk(clk), .d({x0p, x1_in}), .q({x0d, x1d}));

    // ================= LIFT: wrap carry of x0p + x1 =================
    wire lc0, lc1;
    msk_cout_tree #(.N(XW), .REG(DOM_REG)) u_lift (.clk(clk),
        .a0(la0), .a1(la1), .b0(lb0), .b1(lb1),
        .z(rnd_in[O_ZL +: mskf_cout_z(XW)]), .c0(lc0), .c1(lc1));

    // ================= B2A step 1: share-1 side precomputes both options ======
    // e0 + e1 = c*K, c = lc0 ^ lc1. Share 1 prepares (lc1)*K - r0 and
    // (~lc1)*K - r1 with independent masks; share 0 picks one in step 2.
    wire [RW-1:0] kk  = {{(RW-MW){m0_in[MW-1]}}, m0_in} << XW;   // weight of the wrap carry
    wire [RW-1:0] K   = -kk;
    wire [RW-1:0] r0  = {rnd_in[O_R0 +: RH], {XW{1'b0}}};
    wire [RW-1:0] r1  = {rnd_in[O_R1 +: RH], {XW{1'b0}}};
    wire [RW-1:0] mo0 = (lc1 ? K : {RW{1'b0}}) - r0;             // c when lc0 = 0
    wire [RW-1:0] mo1 = (lc1 ? {RW{1'b0}} : K) - r1;             // c when lc0 = 1
    wire [RW-1:0] mo0q, mo1q, r0q, r1q;
    wire          lc0q;
    msk_pipe #(.W(4*RW + 1), .D(R)) u_b2a (.clk(clk),
        .d({mo0, mo1, r0, r1, lc0}), .q({mo0q, mo1q, r0q, r1q, lc0q}));

    // ================= B2A step 2 + per-share linear part + re-mask ===========
    wire signed [BW+1:0] op0 = $signed({{(BW+2-XW){1'b0}}, x0d})
                             - $signed({{(BW+2-XW){1'b0}}, HALF})
                             + $signed({{2{bias_in[BW-1]}}, bias_in});
    wire signed [XW:0]   op1 = $signed({1'b0, x1d});
    wire [RW-1:0] rnd_add = (shift_in == 0) ? {RW{1'b0}} : (ONE << (shift_in - 1));
    wire [RW-1:0] cst     = rnd_add + (ONE << (shift_in + N - 1));    // round + range offset
    wire signed [RW-1:0] prod0 = op0 * m0_in;
    wire signed [RW-1:0] prod1 = op1 * m0_in;
    wire [RW-1:0] A0 = prod0 + cst + (lc0q ? r1q : r0q);
    wire [RW-1:0] A1 = prod1 + (lc0q ? mo1q : mo0q);
    wire [RW-1:0] ra2 = rnd_in[O_RA2 +: RW];
    wire [RW-1:0] rb2 = rnd_in[O_RB2 +: RW];
    wire [RW-1:0] a0, a1, b0, b1;
    msk_pipe #(.W(4*RW), .D(R)) u_rm (.clk(clk),
        .d({A0 ^ ra2, ra2, rb2, A1 ^ rb2}), .q({a0, a1, b0, b1}));

    // ================= A2B: generate / propagate layer =================
    wire [RW-1:0] g0, g1, p0, p1;
    dom_and_v #(.W(RW), .REG(DOM_REG)) u_g (.clk(clk), .a0(a0), .a1(a1), .b0(b0), .b1(b1),
                                            .z(rnd_in[O_ZG +: RW]), .q0(g0), .q1(g1));
    msk_dly #(.W(2*RW), .REG(DOM_REG)) u_p (.clk(clk), .d({a0 ^ b0, a1 ^ b1}), .q({p0, p1}));

    // ================= A2B: prefix tree (carries) =================
    wire [RW-1:0] G0f, G1f;
    msk_prefix #(.N(RW), .REG(DOM_REG)) u_pfx (.clk(clk), .g0(g0), .g1(g1), .p0(p0), .p1(p1),
        .z(rnd_in[O_ZP +: mskf_pfx_z(RW)]), .G0(G0f), .G1(G1f));

    // ================= in-range test, in parallel with the prefix tree =========
    // Q in [0, 2^k), k = shift + N  <=>  sum bits [k, RW) all zero
    //   <=>  s_k = 0  AND  for every i > k: p_i == (a_{i-1} | b_{i-1})
    // a|b = g ^ p, so every term comes from the first layer, no carries.
    // Positions <= k are forced to 1. Pairs in the first AND level are
    // HP bits apart, so neighbouring terms (which share p bits) never meet
    // in one gadget.
    wire [SW:0]   kpos = shift_in + N;
    wire [RW-1:0] keep = {RW{1'b1}} << (kpos + 1);               // positions > k
    // term at position POS (bit 0 unused), forced to 1 (shares 1,0) where POS <= k
    wire [RW-1:0] tt0 = ~(p0 ^ {g0[RW-2:0], 1'b0} ^ {p0[RW-2:0], 1'b0}) | ~keep;
    wire [RW-1:0] tt1 =  (p1 ^ {g1[RW-2:0], 1'b0} ^ {p1[RW-2:0], 1'b0}) &  keep;
    // tree input e takes position 1+e/2 (e even) or 1+HP+(e-1)/2 (e odd)
    reg  [M-1:0]  t0v, t1v;
    integer e;
    always @* begin
        for (e = 0; e < M; e = e + 1) begin
            t0v[e] = tt0[(e % 2 == 0) ? 1 + e/2 : 1 + HP + (e-1)/2];
            t1v[e] = tt1[(e % 2 == 0) ? 1 + e/2 : 1 + HP + (e-1)/2];
        end
    end
    wire Tw0, Tw1, T0, T1;
    msk_and_tree #(.N(M), .REG(DOM_REG)) u_t (.clk(clk), .x0(t0v), .x1(t1v),
        .z(rnd_in[O_ZT +: mskf_and_z(M)]), .y0(Tw0), .y1(Tw1));
    msk_pipe #(.W(2), .D(LPFX - LT)) u_ta (.clk(clk), .d({Tw0, Tw1}), .q({T0, T1}));

    // ================= output window: only N+1 propagate bits travel =========
    wire [RW-1:0] pw0 = p0 >> shift_in;
    wire [RW-1:0] pw1 = p1 >> shift_in;
    wire [N:0]    pd0, pd1;
    wire          pm0, pm1;
    msk_pipe #(.W(2*N + 4), .D(LPFX)) u_pw (.clk(clk),
        .d({pw0[N:0], pw1[N:0], p0[RW-1], p1[RW-1]}), .q({pd0, pd1, pm0, pm1}));

    // carry INTO position m is G[m-1]
    wire [RW-1:0] cv0 = {G0f[RW-2:0], 1'b0};
    wire [RW-1:0] cv1 = {G1f[RW-2:0], 1'b0};
    wire [RW-1:0] cw0 = cv0 >> shift_in;
    wire [RW-1:0] cw1 = cv1 >> shift_in;
    wire [N:0]    s0  = pd0 ^ cw0[N:0];
    wire [N:0]    s1  = pd1 ^ cw1[N:0];
    wire          sg0 = pm0 ^ G0f[RW-2];                          // sign of Q
    wire          sg1 = pm1 ^ G1f[RW-2];
    wire [N-1:0]  y0  = s0[N-1:0] ^ QOFF;                         // undo the +2^(N-1) offset
    wire [N-1:0]  y1  = s1[N-1:0];

    // DOM_REG = 0: one register here to break the long combinational path
    wire [N-1:0] y0m, y1m;
    wire         sk0m, sk1m, sg0m, sg1m, T0m, T1m;
    msk_pipe #(.W(2*N + 6), .D(1 - R)) u_mid (.clk(clk),
        .d({y0, y1, s0[N], s1[N], sg0, sg1, T0, T1}),
        .q({y0m, y1m, sk0m, sk1m, sg0m, sg1m, T0m, T1m}));

    // ================= Z: in range = ~s_k & T =================
    wire Z0, Z1;
    dom_and #(.REG(DOM_REG)) u_z (.clk(clk), .a0(~sk0m), .a1(sk1m), .b0(T0m), .b1(T1m),
                                  .z(rnd_in[O_ZZ]), .q0(Z0), .q1(Z1));
    wire [N-1:0] y0z, y1z;
    wire         sg0z, sg1z;
    msk_pipe #(.W(2*N + 2), .D(R)) u_zd (.clk(clk), .d({y0m, y1m, sg0m, sg1m}), .q({y0z, y1z, sg0z, sg1z}));

    // ================= CLAMP: q = sat_val ^ (Z & (byte ^ sat_val)) ==========
    // sat_val = sign ? 0x80 : 0x7F = 0x7F ^ {N{sign}}  (linear in the sign)
    wire [N-1:0] sv0 = QHI ^ {N{sg0z}};
    wire [N-1:0] sv1 = {N{sg1z}};
    wire [N-1:0] d0  = y0z ^ sv0;
    wire [N-1:0] d1  = y1z ^ sv1;
    wire [N-1:0] w0, w1;
    dom_and_v #(.W(N), .REG(DOM_REG)) u_c (.clk(clk), .a0({N{Z0}}), .a1({N{Z1}}), .b0(d0), .b1(d1),
                                           .z(rnd_in[O_ZC +: N]), .q0(w0), .q1(w1));
    wire [N-1:0] sv0c, sv1c;
    wire         st0c, st1c;
    msk_pipe #(.W(2*N + 2), .D(R)) u_cd (.clk(clk), .d({sv0, sv1, ~Z0, Z1}), .q({sv0c, sv1c, st0c, st1c}));

    // DOM_REG = 0: output register (DOM_REG = 1: outputs are the clamp registers)
    msk_pipe #(.W(2*N + 2), .D(1 - R)) u_out (.clk(clk),
        .d({sv0c ^ w0, sv1c ^ w1, st0c, st1c}), .q({q0_out, q1_out, sat0_out, sat1_out}));

    msk_vpipe #(.D(LAT)) u_v (.clk(clk), .reset_n(reset_n), .d(valid_in), .q(valid_out));
endmodule

// D-cycle delay line (D may be 0)
module msk_pipe #(parameter W = 1, parameter D = 1) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    generate
        if (D == 0) begin : g_w
            assign q = d;
        end else begin : g_r
            reg [W-1:0] s [0:D-1];
            integer i;
            always @(posedge clk) begin
                s[0] <= d;
                for (i = 1; i < D; i = i + 1) s[i] <= s[i-1];
            end
            assign q = s[D-1];
        end
    endgenerate
endmodule

// D-cycle delay line for valid bits, cleared by reset (D may be 0)
module msk_vpipe #(parameter D = 1) (
    input  wire clk,
    input  wire reset_n,
    input  wire d,
    output wire q
);
    generate
        if (D == 0) begin : g_w
            assign q = d;
        end else if (D == 1) begin : g_1
            reg s;
            always @(posedge clk) s <= reset_n ? d : 1'b0;
            assign q = s;
        end else begin : g_r
            reg [D-1:0] s;
            always @(posedge clk) s <= reset_n ? {s[D-2:0], d} : {D{1'b0}};
            assign q = s[D-1];
        end
    endgenerate
endmodule
