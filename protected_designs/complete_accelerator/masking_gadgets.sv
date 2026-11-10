// First-order, 2-share Boolean masking gadgets

module msk_dly #(parameter W = 1, parameter REG = 1) (
    input  wire         clk,
    input  wire [W-1:0] d,
    output wire [W-1:0] q
);
    generate
        if (REG) begin : g_r
            reg [W-1:0] r;
            always @(posedge clk) r <= d;
            assign q = r;
        end else begin : g_w
            assign q = d;
        end
    endgenerate
endmodule

// q = a & b
module dom_and #(parameter REG = 1) (
    input  wire clk,
    input  wire a0, a1, b0, b1, z,
    output wire q0, q1
);
    wire i0 = a0 & b0;
    wire i1 = a1 & b1;
    wire c0 = (a0 & b1) ^ z;
    wire c1 = (a1 & b0) ^ z;
    generate
        if (REG) begin : g_r
            reg ri0, ri1, rc0, rc1;
            always @(posedge clk) begin ri0 <= i0; ri1 <= i1; rc0 <= c0; rc1 <= c1; end
            assign q0 = ri0 ^ rc0;
            assign q1 = ri1 ^ rc1;
        end else begin : g_c
            assign q0 = i0 ^ c0;
            assign q1 = i1 ^ c1;
        end
    endgenerate
endmodule

// Carry-out of A + B (N bits)
module msk_cout_tree (clk, a0, a1, b0, b1, z, c0, c1);
    parameter N   = 8;
    parameter REG = 1;
    `include "msk_counts.vh"
    localparam L  = $clog2(N);
    localparam ZW = mskf_cout_z(N);

    input  wire          clk;
    input  wire [N-1:0]  a0, a1, b0, b1;
    input  wire [ZW-1:0] z;
    output wire          c0, c1;

    // level l, group k lives at index l*N + k
    wire G0 [0:N*(L+1)-1];
    wire G1 [0:N*(L+1)-1];
    wire P0 [0:N*(L+1)-1];
    wire P1 [0:N*(L+1)-1];

    genvar i, l, k;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_lv0
            dom_and #(.REG(REG)) u_g (.clk(clk), .a0(a0[i]), .a1(a1[i]), .b0(b0[i]), .b1(b1[i]),
                                      .z(z[i]), .q0(G0[i]), .q1(G1[i]));
            msk_dly #(.W(2), .REG(REG)) u_p (.clk(clk), .d({a0[i] ^ b0[i], a1[i] ^ b1[i]}),
                                             .q({P0[i], P1[i]}));
        end
        for (l = 0; l < L; l = l + 1) begin : g_lv
            for (k = 0; k < N; k = k + 1) begin : g_k
                localparam integer HI = l*N + 2*k + 1;
                localparam integer LO = l*N + 2*k;
                localparam integer O  = (l+1)*N + k;
                if (k < mskf_m(N, l+1) && 2*k+1 < mskf_m(N, l)) begin : g_comb
                    localparam integer ZO = mskf_cout_zoff(N, l) + 2*k;
                    wire t0, t1, gh0, gh1;
                    dom_and #(.REG(REG)) u_pg (.clk(clk), .a0(P0[HI]), .a1(P1[HI]), .b0(G0[LO]), .b1(G1[LO]),
                                               .z(z[ZO]), .q0(t0), .q1(t1));
                    dom_and #(.REG(REG)) u_pp (.clk(clk), .a0(P0[HI]), .a1(P1[HI]), .b0(P0[LO]), .b1(P1[LO]),
                                               .z(z[ZO+1]), .q0(P0[O]), .q1(P1[O]));
                    msk_dly #(.W(2), .REG(REG)) u_gh (.clk(clk), .d({G0[HI], G1[HI]}), .q({gh0, gh1}));
                    assign G0[O] = gh0 ^ t0;
                    assign G1[O] = gh1 ^ t1;
                end else if (k < mskf_m(N, l+1)) begin : g_pass
                    msk_dly #(.W(4), .REG(REG)) u_d (.clk(clk), .d({G0[LO], G1[LO], P0[LO], P1[LO]}),
                                                     .q({G0[O], G1[O], P0[O], P1[O]}));
                end else begin : g_nc
                    assign G0[O] = 1'b0; assign G1[O] = 1'b0; assign P0[O] = 1'b0; assign P1[O] = 1'b0;
                end
            end
        end
    endgenerate
    assign c0 = G0[L*N];
    assign c1 = G1[L*N];
endmodule

// Sklansky prefix adder
module msk_sklansky (clk, a0, a1, b0, b1, z, s0, s1, co0, co1);
    parameter N   = 16;
    parameter REG = 1;
    `include "msk_counts.vh"
    localparam L  = $clog2(N);
    localparam ZW = mskf_skl_z(N);

    input  wire          clk;
    input  wire [N-1:0]  a0, a1, b0, b1;
    input  wire [ZW-1:0] z;
    output wire [N-1:0]  s0, s1;
    output wire          co0, co1;

    wire G0 [0:N*(L+1)-1];
    wire G1 [0:N*(L+1)-1];
    wire P0 [0:N*(L+1)-1];
    wire P1 [0:N*(L+1)-1];
    wire Q0 [0:N*(L+1)-1];   // original propagate, delayed
    wire Q1 [0:N*(L+1)-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_lv0
            dom_and #(.REG(REG)) u_g (.clk(clk), .a0(a0[i]), .a1(a1[i]), .b0(b0[i]), .b1(b1[i]),
                                      .z(z[i]), .q0(G0[i]), .q1(G1[i]));
            msk_dly #(.W(2), .REG(REG)) u_p (.clk(clk), .d({a0[i] ^ b0[i], a1[i] ^ b1[i]}),
                                             .q({P0[i], P1[i]}));
            assign Q0[i] = P0[i];
            assign Q1[i] = P1[i];
        end
        for (j = 0; j < L; j = j + 1) begin : g_lv
            for (i = 0; i < N; i = i + 1) begin : g_i
                localparam integer C  = j*N + i;
                localparam integer O  = (j+1)*N + i;
                msk_dly #(.W(2), .REG(REG)) u_q (.clk(clk), .d({Q0[C], Q1[C]}), .q({Q0[O], Q1[O]}));
                if ((i >> j) & 1) begin : g_node
                    localparam integer PP = j*N + ((i >> j) << j) - 1;
                    localparam integer ZO = mskf_skl_zoff(N, j) + 2*mskf_skl_rank(i, j);
                    wire t0, t1, gh0, gh1;
                    dom_and #(.REG(REG)) u_pg (.clk(clk), .a0(P0[C]), .a1(P1[C]), .b0(G0[PP]), .b1(G1[PP]),
                                               .z(z[ZO]), .q0(t0), .q1(t1));
                    dom_and #(.REG(REG)) u_pp (.clk(clk), .a0(P0[C]), .a1(P1[C]), .b0(P0[PP]), .b1(P1[PP]),
                                               .z(z[ZO+1]), .q0(P0[O]), .q1(P1[O]));
                    msk_dly #(.W(2), .REG(REG)) u_gh (.clk(clk), .d({G0[C], G1[C]}), .q({gh0, gh1}));
                    assign G0[O] = gh0 ^ t0;
                    assign G1[O] = gh1 ^ t1;
                end else begin : g_pass
                    msk_dly #(.W(4), .REG(REG)) u_d (.clk(clk), .d({G0[C], G1[C], P0[C], P1[C]}),
                                                     .q({G0[O], G1[O], P0[O], P1[O]}));
                end
            end
        end
        // sum_i = p_i ^ carry_in_i, carry_in_i = prefix generate of bits 0..i-1
        for (i = 0; i < N; i = i + 1) begin : g_sum
            if (i == 0) begin : g_s0
                assign s0[0] = Q0[L*N];
                assign s1[0] = Q1[L*N];
            end else begin : g_si
                assign s0[i] = Q0[L*N + i] ^ G0[L*N + i - 1];
                assign s1[i] = Q1[L*N + i] ^ G1[L*N + i - 1];
            end
        end
    endgenerate
    assign co0 = G0[L*N + N - 1];
    assign co1 = G1[L*N + N - 1];
endmodule

// AND of all N shared bits
module msk_and_tree (clk, x0, x1, z, y0, y1);
    parameter N   = 8;
    parameter REG = 1;
    `include "msk_counts.vh"
    localparam L  = $clog2(N);
    localparam ZW = (mskf_and_z(N) > 0) ? mskf_and_z(N) : 1;

    input  wire          clk;
    input  wire [N-1:0]  x0, x1;
    input  wire [ZW-1:0] z;
    output wire          y0, y1;

    wire Y0 [0:N*(L+1)-1];
    wire Y1 [0:N*(L+1)-1];

    genvar l, k;
    generate
        for (k = 0; k < N; k = k + 1) begin : g_in
            assign Y0[k] = x0[k];
            assign Y1[k] = x1[k];
        end
        for (l = 0; l < L; l = l + 1) begin : g_lv
            for (k = 0; k < N; k = k + 1) begin : g_k
                localparam integer HI = l*N + 2*k + 1;
                localparam integer LO = l*N + 2*k;
                localparam integer O  = (l+1)*N + k;
                if (k < mskf_m(N, l+1) && 2*k+1 < mskf_m(N, l)) begin : g_comb
                    dom_and #(.REG(REG)) u_a (.clk(clk), .a0(Y0[HI]), .a1(Y1[HI]), .b0(Y0[LO]), .b1(Y1[LO]),
                                              .z(z[mskf_and_zoff(N, l) + k]), .q0(Y0[O]), .q1(Y1[O]));
                end else if (k < mskf_m(N, l+1)) begin : g_pass
                    msk_dly #(.W(2), .REG(REG)) u_d (.clk(clk), .d({Y0[LO], Y1[LO]}), .q({Y0[O], Y1[O]}));
                end else begin : g_nc
                    assign Y0[O] = 1'b0; assign Y1[O] = 1'b0;
                end
            end
        end
    endgenerate
    assign y0 = Y0[L*N];
    assign y1 = Y1[L*N];
endmodule

// W fresh random bits per cycle from ceil(W/64) xorshift64 generators
module rng_bank #(
    parameter W = 64,
    parameter [63:0] SEED = 64'h0123_4567_89AB_CDEF
) (
    input  wire         clk,
    input  wire         reset_n,
    input  wire         en,
    output wire [W-1:0] rnd
);
    localparam NG = (W + 63) / 64;
    wire [NG*64-1:0] all;
    genvar g;
    generate
        for (g = 0; g < NG; g = g + 1) begin : g_x
            reg  [63:0] x;
            wire [63:0] x1 = x  ^ (x  << 13);
            wire [63:0] x2 = x1 ^ (x1 >> 7);
            wire [63:0] x3 = x2 ^ (x2 << 17);
            always @(posedge clk) begin
                if (!reset_n) x <= SEED ^ (64'h9E37_79B9_7F4A_7C15 * (g + 1));
                else if (en)  x <= x3;
            end
            assign all[g*64 +: 64] = x;
        end
    endgenerate
    assign rnd = all[W-1:0];
endmodule

// msk_prefix
module msk_prefix (clk, g0, g1, p0, p1, z, G0, G1);
    parameter N   = 16;
    parameter REG = 1;
    `include "msk_counts.vh"
    localparam L  = $clog2(N);
    localparam ZW = (mskf_pfx_z(N) > 0) ? mskf_pfx_z(N) : 1;

    input  wire          clk;
    input  wire [N-1:0]  g0, g1, p0, p1;
    input  wire [ZW-1:0] z;
    output wire [N-1:0]  G0, G1;

    wire Gs0 [0:N*(L+1)-1];
    wire Gs1 [0:N*(L+1)-1];
    wire Ps0 [0:N*(L+1)-1];
    wire Ps1 [0:N*(L+1)-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_in
            assign Gs0[i] = g0[i];
            assign Gs1[i] = g1[i];
            assign Ps0[i] = p0[i];
            assign Ps1[i] = p1[i];
        end
        for (j = 0; j < L; j = j + 1) begin : g_lv
            for (i = 0; i < N; i = i + 1) begin : g_i
                localparam integer C    = j*N + i;
                localparam integer O    = (j+1)*N + i;
                localparam integer LAST = (j == L-1);
                if ((i >> j) & 1) begin : g_node
                    localparam integer PP = j*N + ((i >> j) << j) - 1;
                    localparam integer ZO = mskf_pfx_zoff(N, j) + (LAST ? 1 : 2) * mskf_skl_rank(i, j);
                    wire t0, t1, gh0, gh1;
                    dom_and #(.REG(REG)) u_pg (.clk(clk), .a0(Ps0[C]), .a1(Ps1[C]), .b0(Gs0[PP]), .b1(Gs1[PP]),
                                               .z(z[ZO]), .q0(t0), .q1(t1));
                    msk_dly #(.W(2), .REG(REG)) u_gh (.clk(clk), .d({Gs0[C], Gs1[C]}), .q({gh0, gh1}));
                    assign Gs0[O] = gh0 ^ t0;
                    assign Gs1[O] = gh1 ^ t1;
                    if (!LAST) begin : g_p
                        dom_and #(.REG(REG)) u_pp (.clk(clk), .a0(Ps0[C]), .a1(Ps1[C]), .b0(Ps0[PP]), .b1(Ps1[PP]),
                                                   .z(z[ZO+1]), .q0(Ps0[O]), .q1(Ps1[O]));
                    end else begin : g_np
                        assign Ps0[O] = 1'b0;
                        assign Ps1[O] = 1'b0;
                    end
                end else begin : g_pass
                    msk_dly #(.W(2), .REG(REG)) u_g (.clk(clk), .d({Gs0[C], Gs1[C]}), .q({Gs0[O], Gs1[O]}));
                    if (!LAST) begin : g_p
                        msk_dly #(.W(2), .REG(REG)) u_p (.clk(clk), .d({Ps0[C], Ps1[C]}), .q({Ps0[O], Ps1[O]}));
                    end else begin : g_np
                        assign Ps0[O] = 1'b0;
                        assign Ps1[O] = 1'b0;
                    end
                end
            end
        end
        for (i = 0; i < N; i = i + 1) begin : g_out
            assign G0[i] = Gs0[L*N + i];
            assign G1[i] = Gs1[L*N + i];
        end
    endgenerate
endmodule

// dom_and_v
module dom_and_v #(parameter W = 1, parameter REG = 1) (
    input  wire         clk,
    input  wire [W-1:0] a0, a1, b0, b1, z,
    output wire [W-1:0] q0, q1
);
    wire [W-1:0] i0 = a0 & b0;
    wire [W-1:0] i1 = a1 & b1;
    wire [W-1:0] c0 = (a0 & b1) ^ z;
    wire [W-1:0] c1 = (a1 & b0) ^ z;
    generate
        if (REG) begin : g_r
            reg [W-1:0] ri0, ri1, rc0, rc1;
            always @(posedge clk) begin ri0 <= i0; ri1 <= i1; rc0 <= c0; rc1 <= c1; end
            assign q0 = ri0 ^ rc0;
            assign q1 = ri1 ^ rc1;
        end else begin : g_c
            assign q0 = i0 ^ c0;
            assign q1 = i1 ^ c1;
        end
    endgenerate
endmodule
