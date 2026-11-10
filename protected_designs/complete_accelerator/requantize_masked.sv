// First-order masked TFLite requantizer, same function as requantize
module requantize_masked (clk, reset_n, valid_in, col_in, x0_in, x1_in, bm_tab, m0_tab, shift_tab,
                          rnd_in, valid_out, col_out, q0_out, q1_out, sat0_out, sat1_out);
    parameter N       = 8;
    parameter XW      = 19;
    parameter MW      = 16;
    parameter SW      = 6;            // shift width
    parameter BMW     = 48;           // width of the bias*m0 table entries
    parameter RW      = XW + MW + 2;  // internal ring width
    parameter DOM_REG = 1;
    parameter NC      = 1;            // entries in the constant tables
    parameter CIW     = (NC > 1) ? $clog2(NC) : 1;

    `include "msk_counts.vh"

    localparam RND_W = mskf_rq_rnd(XW, RW);
    localparam LAT   = mskf_rq_lat(XW, RW, DOM_REG);
    localparam R     = DOM_REG ? 1 : 0;              // robustness register stage on/off
    localparam LIFT  = R ? 1 + $clog2(XW) : 0;       // carry-tree latency
    localparam LPFX  = R ? $clog2(RW) : 0;           // prefix-tree latency
    localparam LT    = R ? $clog2(RW - 1) : 0;       // zero-detect tree latency
    localparam LM    = R ? 2 : 0;                    // per-share multiplier stages
    localparam DX    = 1 + LIFT + R - LM;            // narrow share delay before the multiplier
    localparam RH    = RW - XW;                      // B2A masks live in bits >= XW
    localparam M     = RW - 1;                       // zero-detect terms (positions 1..RW-1)
    localparam HP    = (M + 1) / 2;                  // pair distance in the zero-detect tree
    localparam LH    = MW / 2;                       // m0 split for the 2-stage multiplier
    // pipeline stage (cycles after valid_in) at which each constant is used
    localparam S_MUL = DX;                           // multiplier stage 1, K precompute
    localparam S_B2A = 1 + LIFT;                     // B2A step 1 (K), K0 precompute
    localparam S_A2B = 1 + LIFT + 2*R;               // first A2B layer (in-range mask precompute)
    localparam S_PW  = S_A2B + R;                    // output window shift of p
    localparam S_CW  = S_PW + LPFX;                  // output window shift of the carries

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
    input  wire [CIW-1:0]         col_in;
    input  wire [XW-1:0]          x0_in, x1_in;
    input  wire [NC*BMW-1:0]      bm_tab;
    input  wire [NC*MW-1:0]       m0_tab;
    input  wire [NC*SW-1:0]       shift_tab;
    input  wire [RND_W-1:0]       rnd_in;
    output wire                   valid_out;
    output wire [CIW-1:0]         col_out;
    output wire [N-1:0]           q0_out, q1_out;
    output wire                   sat0_out, sat1_out;

    localparam [RW-1:0] ONE   = {{(RW-1){1'b0}}, 1'b1};
    localparam [XW-1:0] HALF  = {1'b1, {(XW-1){1'b0}}};
    localparam [N-1:0]  QHI   = {1'b0, {(N-1){1'b1}}};      // 0x7F
    localparam [N-1:0]  QOFF  = {1'b1, {(N-1){1'b0}}};      // 0x80

    // column tag pipeline (public)
    wire [CIW-1:0] ct [0:LAT];
    assign ct[0] = col_in;
    genvar gk;
    generate
        for (gk = 1; gk <= LAT; gk = gk + 1) begin : g_ct
            reg [CIW-1:0] t;
            always @(posedge clk) t <= ct[gk-1];
            assign ct[gk] = t;
        end
    endgenerate
    assign col_out = ct[LAT];

    // table entry of column tag c

    // input shares
    wire [XW-1:0] x0p = x0_in + HALF;                       // offset share 0
    wire [XW-1:0] ra1 = rnd_in[O_RA1 +: XW];
    wire [XW-1:0] rb1 = rnd_in[O_RB1 +: XW];
    wire [XW-1:0] la0, la1, lb0, lb1;
    msk_pipe #(.W(4*XW), .D(1)) u_in (.clk(clk),
        .d({x0p ^ ra1, ra1, rb1, x1_in ^ rb1}), .q({la0, la1, lb0, lb1}));

    // arithmetic shares travel narrow (XW bits) to the multiplier
    wire [XW-1:0] x0d, x1d;
    msk_pipe #(.W(2*XW), .D(DX)) u_x (.clk(clk), .d({x0p, x1_in}), .q({x0d, x1d}));

    // per-share x*m0, LM stages (one share per cone)
    wire [MW-1:0]        m0m = m0_tab[ct[S_MUL]*MW +: MW];
    wire signed [XW-1:0] op0 = $signed({~x0d[XW-1], x0d[XW-2:0]});
    wire signed [XW:0]   op1 = $signed({1'b0, x1d});
    wire signed [RW-1:0] prod0, prod1;
    generate
        if (LM == 0) begin : g_mul_c
            assign prod0 = op0 * $signed(m0m);
            assign prod1 = op1 * $signed(m0m);
        end else begin : g_mul_p
            // stage 1
            wire signed [XW+LH:0]      pl0 = op0 * $signed({1'b0, m0m[LH-1:0]});
            wire signed [XW+MW-LH-1:0] ph0 = op0 * $signed(m0m[MW-1:LH]);
            wire signed [XW+LH+1:0]    pl1 = op1 * $signed({1'b0, m0m[LH-1:0]});
            wire signed [XW+MW-LH:0]   ph1 = op1 * $signed(m0m[MW-1:LH]);
            reg  signed [XW+LH:0]      pl0q;
            reg  signed [XW+MW-LH-1:0] ph0q;
            reg  signed [XW+LH+1:0]    pl1q;
            reg  signed [XW+MW-LH:0]   ph1q;
            // stage 2
            reg  signed [RW-1:0]       pr0q, pr1q;
            always @(posedge clk) begin
                pl0q <= pl0;  ph0q <= ph0;
                pl1q <= pl1;  ph1q <= ph1;
                pr0q <= pl0q + (ph0q <<< LH);
                pr1q <= pl1q + (ph1q <<< LH);
            end
            assign prod0 = pr0q;
            assign prod1 = pr1q;
        end
    endgenerate

    // lift stage
    wire lc0, lc1;
    msk_cout_tree #(.N(XW), .REG(DOM_REG)) u_lift (.clk(clk),
        .a0(la0), .a1(la1), .b0(lb0), .b1(lb1),
        .z(rnd_in[O_ZL +: mskf_cout_z(XW)]), .c0(lc0), .c1(lc1));

    // public constants, registered one stage before use
    wire [MW-1:0] m0k = m0_tab[ct[S_B2A - R]*MW +: MW];
    wire [RW-1:0] Kc  = -({{(RW-MW){m0k[MW-1]}}, m0k} << XW);
    wire [SW-1:0] shk = shift_tab[ct[S_B2A]*SW +: SW];
    wire [RW-1:0] rnk = (shk == 0) ? {RW{1'b0}} : (ONE << (shk - 1));
    wire [RW-1:0] K0c = bm_tab[ct[S_B2A]*BMW +: RW] + rnk + (ONE << (shk + N - 1));
    wire [SW-1:0] shp = shift_tab[ct[S_A2B]*SW +: SW];
    wire [SW:0]   kpk = shp + N;
    wire [RW-1:0] kpc = {RW{1'b1}} << (kpk + 1);
    wire [RW-1:0] K, K0, keep;
    msk_pipe #(.W(RW), .D(R)) u_kk (.clk(clk), .d(Kc),  .q(K));
    msk_pipe #(.W(RW), .D(R)) u_k0 (.clk(clk), .d(K0c), .q(K0));
    msk_pipe #(.W(RW), .D(R)) u_kp (.clk(clk), .d(kpc), .q(keep));

    // B2A step 1
    wire [RW-1:0] r0  = {rnd_in[O_R0 +: RH], {XW{1'b0}}};
    wire [RW-1:0] r1  = {rnd_in[O_R1 +: RH], {XW{1'b0}}};
    wire [RW-1:0] mo0 = (lc1 ? K : {RW{1'b0}}) - r0;             // c when lc0 = 0
    wire [RW-1:0] mo1 = (lc1 ? {RW{1'b0}} : K) - r1;             // c when lc0 = 1
    wire [RW-1:0] mo0q, mo1q, r0q, r1q;
    wire          lc0q;
    msk_pipe #(.W(4*RW + 1), .D(R)) u_b2a (.clk(clk),
        .d({mo0, mo1, r0, r1, lc0}), .q({mo0q, mo1q, r0q, r1q, lc0q}));

    // B2A step 2 + per-share constant + re-mask
    wire [RW-1:0] A0 = prod0 + K0 + (lc0q ? r1q : r0q);
    wire [RW-1:0] A1 = prod1 + (lc0q ? mo1q : mo0q);
    wire [RW-1:0] ra2 = rnd_in[O_RA2 +: RW];
    wire [RW-1:0] rb2 = rnd_in[O_RB2 +: RW];
    wire [RW-1:0] a0, a1, b0, b1;
    msk_pipe #(.W(4*RW), .D(R)) u_rm (.clk(clk),
        .d({A0 ^ ra2, ra2, rb2, A1 ^ rb2}), .q({a0, a1, b0, b1}));

    // A2B conversion
    wire [RW-1:0] g0, g1, p0, p1;
    dom_and_v #(.W(RW), .REG(DOM_REG)) u_g (.clk(clk), .a0(a0), .a1(a1), .b0(b0), .b1(b1),
                                            .z(rnd_in[O_ZG +: RW]), .q0(g0), .q1(g1));
    msk_dly #(.W(2*RW), .REG(DOM_REG)) u_p (.clk(clk), .d({a0 ^ b0, a1 ^ b1}), .q({p0, p1}));

    // A2B conversion
    wire [RW-1:0] G0f, G1f;
    msk_prefix #(.N(RW), .REG(DOM_REG)) u_pfx (.clk(clk), .g0(g0), .g1(g1), .p0(p0), .p1(p1),
        .z(rnd_in[O_ZP +: mskf_pfx_z(RW)]), .G0(G0f), .G1(G1f));

    // in-range test, in parallel with the prefix tree
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

    // output window
    wire [SW-1:0] shw = shift_tab[ct[S_PW]*SW +: SW];
    wire [RW-1:0] pw0 = p0 >> shw;
    wire [RW-1:0] pw1 = p1 >> shw;
    wire [N:0]    pd0, pd1;
    wire          pm0, pm1;
    msk_pipe #(.W(2*N + 4), .D(LPFX)) u_pw (.clk(clk),
        .d({pw0[N:0], pw1[N:0], p0[RW-1], p1[RW-1]}), .q({pd0, pd1, pm0, pm1}));

    // carry INTO position m is G[m-1]
    wire [SW-1:0] shc = shift_tab[ct[S_CW]*SW +: SW];
    wire [RW-1:0] cv0 = {G0f[RW-2:0], 1'b0};
    wire [RW-1:0] cv1 = {G1f[RW-2:0], 1'b0};
    wire [RW-1:0] cw0 = cv0 >> shc;
    wire [RW-1:0] cw1 = cv1 >> shc;
    wire [N:0]    s0  = pd0 ^ cw0[N:0];
    wire [N:0]    s1  = pd1 ^ cw1[N:0];
    wire          sg0 = pm0 ^ G0f[RW-2];                          // sign of Q
    wire          sg1 = pm1 ^ G1f[RW-2];
    wire [N-1:0]  y0  = s0[N-1:0] ^ QOFF;                         // undo the +2^(N-1) offset
    wire [N-1:0]  y1  = s1[N-1:0];

    // DOM_REG = 0
    wire [N-1:0] y0m, y1m;
    wire         sk0m, sk1m, sg0m, sg1m, T0m, T1m;
    msk_pipe #(.W(2*N + 6), .D(1 - R)) u_mid (.clk(clk),
        .d({y0, y1, s0[N], s1[N], sg0, sg1, T0, T1}),
        .q({y0m, y1m, sk0m, sk1m, sg0m, sg1m, T0m, T1m}));

    // zero test
    wire Z0, Z1;
    dom_and #(.REG(DOM_REG)) u_z (.clk(clk), .a0(~sk0m), .a1(sk1m), .b0(T0m), .b1(T1m),
                                  .z(rnd_in[O_ZZ]), .q0(Z0), .q1(Z1));
    wire [N-1:0] y0z, y1z;
    wire         sg0z, sg1z;
    msk_pipe #(.W(2*N + 2), .D(R)) u_zd (.clk(clk), .d({y0m, y1m, sg0m, sg1m}), .q({y0z, y1z, sg0z, sg1z}));

    // clamp to INT8
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

    // DOM_REG = 0
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
