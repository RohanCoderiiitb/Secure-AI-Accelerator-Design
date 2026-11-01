//=====================================================================
// requantize_masked.sv -- exact masked equivalent of requantization_block
//   q = clamp8( ((acc + bias) * m0 + round) >>> shift ),  sat = clamp active
// acc arrives as two ARITHMETIC shares (mod 2^ACCW); bias, m0 and shift are
// PUBLIC configuration. q and sat leave as BOOLEAN shares.
//
//   T0   b0 = acc0 + bias                       linear
//   A2B  masked Kogge-Stone, K = ACCW           arithmetic -> Boolean
//        sign-extend each Boolean share to PW = ACCW + MW bits (exact, free)
//   B2A  Goubin, K = PW                         Boolean -> arithmetic
//   MUL  share-wise  x m0 (structural mul_trunc), + round on share 0 (linear)
//   A2B  masked Kogge-Stone, K = PW
//   SHR  per-share arithmetic right shift by public `shift` (XOR-linear)
//   CLP  masked OR of (v_i ^ sign), i in [PW-2 : N-1]  -> nz;  q = nz ? ~sign : v
//        sat = nz,  q[N-1] = sign
// Latency rq_lat(ACCW,PW,N) register stages (29 for 32/64/8); one result
// per cycle (fully pipelined). Fresh-mask bus layout (offsets below).
// Wrap behaviour (32-bit bias add, 64-bit product + round) is identical to
// the baseline because all arithmetic is modular.
//=====================================================================
module requantize_masked #(
    parameter N    = 8,
    parameter ACCW = 32,
    parameter MW   = 32,
    parameter SW   = 6,
    parameter PW   = ACCW + MW,
    parameter RB   = masked_pkg::rq_rnd(ACCW, PW, N)
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 valid_in,
    input  wire [ACCW-1:0]      acc0_in, acc1_in,        // arithmetic shares
    input  wire [ACCW-1:0]      bias_in,                 // public
    input  wire [MW-1:0]        m0_in,                   // public, signed
    input  wire [SW-1:0]        shift_in,                // public
    input  wire [RB-1:0]        rnd,
    output wire                 valid_out,
    output reg  [N-1:0]         q0_out, q1_out,          // Boolean shares
    output reg                  sat0_out, sat1_out
);
    localparam LA1 = masked_pkg::ks_lat(ACCW);
    localparam LB  = masked_pkg::B2A_LAT;
    localparam LA2 = masked_pkg::ks_lat(PW);
    localparam NB  = PW - N;                              // bits [PW-2 : N-1] xor sign -> PW-N bits
    localparam LOR = masked_pkg::or_lat(NB);
    localparam RQ_LAT = 1 + LA1 + LB + 1 + LA2 + 1 + LOR + 1 + 1;   // == masked_pkg::rq_lat
    localparam R_KS1 = masked_pkg::ks_rnd(ACCW);
    localparam R_KS2 = masked_pkg::ks_rnd(PW);
    localparam R_OR  = masked_pkg::or_rnd(NB);
    localparam O_KS1 = 0;
    localparam O_B2A = R_KS1;
    localparam O_KS2 = O_B2A + PW;
    localparam O_OR  = O_KS2 + R_KS2;
    localparam O_MUX = O_OR  + R_OR;

    // ---------------- T0: bias add + public sidecars ----------------
    reg [ACCW-1:0] b0, b1;
    reg            v_t0;
    reg [MW-1:0]   m0_t0;
    reg [SW-1:0]   sh_t0;
    always @(posedge clk) begin
        if (!reset_n) begin b0 <= 0; b1 <= 0; v_t0 <= 1'b0; m0_t0 <= 0; sh_t0 <= 0; end
        else begin
            b0 <= acc0_in + bias_in;
            b1 <= acc1_in;
            v_t0 <= valid_in; m0_t0 <= m0_in; sh_t0 <= shift_in;
        end
    end

    // ---------------- A2B (K = ACCW) ----------------
    wire [ACCW-1:0] B0, B1;
    masked_ks_adder #(.K(ACCW)) u_a2b1 (
        .clk(clk), .x0(b0), .x1({ACCW{1'b0}}), .y0({ACCW{1'b0}}), .y1(b1),
        .rnd(rnd[O_KS1 +: R_KS1]), .s0(B0), .s1(B1));

    wire [PW-1:0] E0 = {{(PW-ACCW){B0[ACCW-1]}}, B0};     // exact Boolean sign extension
    wire [PW-1:0] E1 = {{(PW-ACCW){B1[ACCW-1]}}, B1};

    // ---------------- B2A (K = PW) ----------------
    wire [PW-1:0] Aa, Ar;
    goubin_b2a #(.K(PW)) u_b2a (.clk(clk), .xp(E0), .r(E1), .g(rnd[O_B2A +: PW]), .A(Aa), .rout(Ar));

    // public sidecars aligned to the multiplier stage (tau + LA1 + LB)
    wire [MW-1:0] m0_m;
    wire [SW-1:0] sh_r;
    delay_line #(.W(MW), .D(LA1+LB)) u_dm0 (.clk(clk), .d(m0_t0), .q(m0_m));
    delay_line #(.W(SW), .D(LA1+LB)) u_dsr (.clk(clk), .d(sh_t0), .q(sh_r));

    // ---------------- share-wise multiply by m0 (+ round on share 0) ----------------
    wire [PW-1:0] pm0, pm1;
    mul_trunc #(.NA(MW), .M(PW)) u_mul0 (.a(m0_m), .w(Aa), .p(pm0));
    mul_trunc #(.NA(MW), .M(PW)) u_mul1 (.a(m0_m), .w(Ar), .p(pm1));
    wire [PW-1:0] round_add = (sh_r == 0) ? {PW{1'b0}} : ({{(PW-1){1'b0}}, 1'b1} << (sh_r - 1'b1));

    reg [PW-1:0] pr0, pr1;
    always @(posedge clk) begin
        pr0 <= pm0 + round_add;
        pr1 <= pm1;
    end

    // ---------------- A2B (K = PW) ----------------
    wire [PW-1:0] V0, V1;
    masked_ks_adder #(.K(PW)) u_a2b2 (
        .clk(clk), .x0(pr0), .x1({PW{1'b0}}), .y0({PW{1'b0}}), .y1(pr1),
        .rnd(rnd[O_KS2 +: R_KS2]), .s0(V0), .s1(V1));

    // ---------------- arithmetic right shift per share (public amount) ----------------
    wire [SW-1:0] sh_s;
    delay_line #(.W(SW), .D(LA1+LB+1+LA2)) u_dss (.clk(clk), .d(sh_t0), .q(sh_s));
    wire signed [PW-1:0] V0s = V0;
    wire signed [PW-1:0] V1s = V1;
    wire [PW-1:0] S0c = V0s >>> sh_s;
    wire [PW-1:0] S1c = V1s >>> sh_s;
    reg  [PW-1:0] S0, S1;
    always @(posedge clk) begin S0 <= S0c; S1 <= S1c; end

    // ---------------- clamp ----------------
    wire sg0 = S0[PW-1];
    wire sg1 = S1[PW-1];
    wire [NB-1:0] T0v = S0[PW-2:N-1] ^ {NB{sg0}};          // v_i ^ sign (XOR-linear)
    wire [NB-1:0] T1v = S1[PW-2:N-1] ^ {NB{sg1}};
    wire nz0, nz1;
    masked_or_tree #(.NB(NB)) u_or (.clk(clk), .t0(T0v), .t1(T1v),
                                    .rnd(rnd[O_OR +: R_OR]), .o0(nz0), .o1(nz1));

    wire [N-2:0] Sl0, Sl1; wire sgd0, sgd1;
    delay_line #(.W(N-1), .D(LOR)) u_sl0 (.clk(clk), .d(S0[N-2:0]), .q(Sl0));
    delay_line #(.W(N-1), .D(LOR)) u_sl1 (.clk(clk), .d(S1[N-2:0]), .q(Sl1));
    delay_line #(.W(1),   .D(LOR)) u_sg0 (.clk(clk), .d(sg0), .q(sgd0));
    delay_line #(.W(1),   .D(LOR)) u_sg1 (.clk(clk), .d(sg1), .q(sgd1));

    // d = v ^ ~sign (share-wise; invert ONE share), AND with nz (replicated)
    wire [N-2:0] d0 = Sl0 ^ {(N-1){~sgd0}};
    wire [N-2:0] d1 = Sl1 ^ {(N-1){sgd1}};
    wire [N-2:0] mz0, mz1;
    dom_and #(.W(N-1)) u_mux (.clk(clk), .x0({(N-1){nz0}}), .x1({(N-1){nz1}}), .y0(d0), .y1(d1),
                              .r(rnd[O_MUX +: (N-1)]), .z0(mz0), .z1(mz1));

    wire [N-2:0] Slm0, Slm1; wire sgm0, sgm1, nzm0, nzm1;
    delay_line #(.W(N-1), .D(1)) u_m0 (.clk(clk), .d(Sl0), .q(Slm0));
    delay_line #(.W(N-1), .D(1)) u_m1 (.clk(clk), .d(Sl1), .q(Slm1));
    delay_line #(.W(1),   .D(1)) u_n0 (.clk(clk), .d(sgd0), .q(sgm0));
    delay_line #(.W(1),   .D(1)) u_n1 (.clk(clk), .d(sgd1), .q(sgm1));
    delay_line #(.W(1),   .D(1)) u_s0 (.clk(clk), .d(nz0),  .q(nzm0));
    delay_line #(.W(1),   .D(1)) u_s1 (.clk(clk), .d(nz1),  .q(nzm1));

    always @(posedge clk) begin
        q0_out   <= {sgm0, Slm0 ^ mz0};                    // q[6:0] = v ^ (nz & (v ^ ~sign)),  q7 = sign
        q1_out   <= {sgm1, Slm1 ^ mz1};
        sat0_out <= nzm0;
        sat1_out <= nzm1;
    end

    // valid: input -> output = rq_lat register stages (T0 counts as stage 1)
    delay_line #(.W(1), .D(RQ_LAT - 1)) u_dv (.clk(clk), .d(v_t0), .q(valid_out));
endmodule
