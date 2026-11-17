// NRQ masked requantizer cores shared round-robin by COLS columns
// each core is followed by one masked activation unit, so outputs leave as activated shares
module rq_share_server #(
    parameter N       = 8,
    parameter XW      = 19,
    parameter MW      = 16,
    parameter SW      = 6,
    parameter BMW     = 48,
    parameter COLS    = 5,
    parameter WAVES   = 4,
    parameter NRQ     = COLS,
    parameter DOM_REG = 1,
    parameter SPLIT   = 0,
    parameter [63:0] SEED = 64'hC0FF_EE00_0000_0001
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire [COLS-1:0]      valid_in,
    input  wire [COLS*XW-1:0]   x0_flat,      // share 0 (SPLIT = 1: plain value)
    input  wire [COLS*XW-1:0]   x1_flat,      // share 1 (unused when SPLIT = 1)
    input  wire [COLS*BMW-1:0]  bm_flat,
    input  wire [COLS*MW-1:0]   m0_flat,
    input  wire [COLS*SW-1:0]   shift_flat,
    input  wire [1:0]           act_mode,      // activation config (public)
    input  wire signed [N-1:0]  act_clamp_high,
    input  wire [2:0]           act_leaky_shift,
    output wire [COLS-1:0]      valid_out,
    output wire [COLS*N-1:0]    q0_flat,      // gated with valid_out
    output wire [COLS*N-1:0]    q1_flat,
    output wire [COLS-1:0]      sat0_flat,
    output wire [COLS-1:0]      sat1_flat
);
    `include "msk_counts.vh"
    localparam RW    = XW + MW + 2;
    localparam RND_W = mskf_rq_rnd(XW, RW);
    localparam LAT   = mskf_rq_lat(XW, RW, DOM_REG);
    localparam NKMAX = (COLS + NRQ - 1) / NRQ;              // columns per core (max)
    localparam CIW   = (NKMAX > 1) ? $clog2(NKMAX) : 1;
    localparam FD    = (NRQ >= COLS) ? 1 : WAVES;           // buffer depth per column
    localparam FAW   = (FD > 1) ? $clog2(FD) : 1;
    localparam NSH   = SPLIT ? 1 : 2;                       // shares stored per value
    localparam LACT  = DOM_REG ? 2 + $clog2(N) : 1;         // masked activation latency
    localparam ZACT  = mskf_cout_z(N) + 2*(N-1);            // its random bits per cycle

    // per-column share buffer
    wire [COLS-1:0]    nonempty;
    wire [COLS-1:0]    pop;
    wire [XW-1:0]      head0 [0:COLS-1];
    wire [XW-1:0]      head1 [0:COLS-1];

    // two shares in: every column's pair gets its own fresh offset (x0 + r, x1 - r) as it is stored.
    // The array masks all columns of a wave with the same shadow sum, so without this two columns
    // would follow each other into a core under the same mask.
    wire [COLS*XW-1:0] rfr;
    generate
        if (!SPLIT) begin : g_rfr
            rng_bank #(.W(COLS*XW), .SEED(SEED ^ 64'h5EED_0F_5EED_0F_55)) u_rfr (
                .clk(clk), .reset_n(reset_n), .en(|valid_in), .rnd(rfr));
        end else begin : g_nrfr
            assign rfr = {(COLS*XW){1'b0}};
        end
    endgenerate

    genvar c, k, j;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_buf
            // flat vectors (not reg arrays) so the buffer contents are visible in a VCD dump of this scope
            reg [FD*XW-1:0] b0;                             // share 0 (or plain value)
            reg [FD*XW-1:0] b1;                             // share 1
            reg [FAW-1:0] wp, rp;
            reg [FAW:0]   cnt;
            wire          push = valid_in[c];
            always @(posedge clk) begin
                if (!reset_n) begin
                    wp <= {FAW{1'b0}}; rp <= {FAW{1'b0}}; cnt <= {(FAW+1){1'b0}};
                end else begin
                    if (push) begin
                        b0[wp*XW +: XW] <= x0_flat[c*XW +: XW] + rfr[c*XW +: XW];
                        if (!SPLIT) b1[wp*XW +: XW] <= x1_flat[c*XW +: XW] - rfr[c*XW +: XW];
                        wp <= (wp == FD-1) ? {FAW{1'b0}} : wp + 1'b1;
                    end
                    if (pop[c]) rp <= (rp == FD-1) ? {FAW{1'b0}} : rp + 1'b1;
                    cnt <= cnt + push - pop[c];
                end
            end
            assign nonempty[c] = (cnt != 0);
            assign head0[c]    = b0[rp*XW +: XW];
            assign head1[c]    = SPLIT ? {XW{1'b0}} : b1[rp*XW +: XW];
`ifndef SYNTHESIS
            always @(posedge clk)
                if (reset_n && push && cnt == FD && !pop[c])
                    $display("[RQS] ERROR: share buffer of column %0d overflowed at t=%0t", c, $time);
`endif
        end
    endgenerate

    wire [N-1:0]   cq0  [0:NRQ-1];
    wire [N-1:0]   cq1  [0:NRQ-1];
    wire           cs0  [0:NRQ-1];
    wire           cs1  [0:NRQ-1];
    wire           cv   [0:NRQ-1];
    wire [CIW-1:0] ctag [0:NRQ-1];
    wire [NRQ*COLS-1:0] pop_k;

    generate
        for (k = 0; k < NRQ; k = k + 1) begin : g_core
            localparam NK = (COLS - k + NRQ - 1) / NRQ;     // columns k, k+NRQ, ...

            // round-robin pick among this core's columns
            wire [NKMAX-1:0] ne;
            for (j = 0; j < NKMAX; j = j + 1) begin : g_ne
                if (j < NK) begin : g_on
                    assign ne[j] = nonempty[j*NRQ + k];
                end else begin : g_off
                    assign ne[j] = 1'b0;
                end
            end
            reg [CIW-1:0] rr;                               // last local column served
            reg           pick;
            reg [CIW-1:0] sel;
            integer i, cand;
            always @* begin
                pick = 1'b0;
                sel  = rr;
                for (i = 1; i <= NK; i = i + 1) begin
                    cand = (rr + i) % NK;
                    if (!pick && ne[cand]) begin
                        pick = 1'b1;
                        sel  = cand;
                    end
                end
            end
            for (c = 0; c < COLS; c = c + 1) begin : g_pop
                if (c % NRQ == k) begin : g_own
                    assign pop_k[k*COLS + c] = pick && (sel == c / NRQ);
                end else begin : g_no
                    assign pop_k[k*COLS + c] = 1'b0;
                end
            end

            // share select register (one register per share)
            reg           iv;
            reg [CIW-1:0] itag;
            reg [XW-1:0]  ix0, ix1;
            always @(posedge clk) begin
                if (!reset_n) begin
                    iv <= 1'b0; rr <= {CIW{1'b0}};
                end else begin
                    iv <= pick;
                    if (pick) rr <= sel;
                end
                if (pick) itag <= sel;
                // zeros when no value is picked, so a value never stays in the core after its slot
                ix0 <= pick ? head0[sel*NRQ + k] : {XW{1'b0}};
                ix1 <= pick ? head1[sel*NRQ + k] : {XW{1'b0}};
            end

            // randomness
            reg [7:0] busy;
            always @(posedge clk) begin
                if (!reset_n)          busy <= 8'd0;
                else if (pick)         busy <= LAT + LACT + 2;
                else if (busy != 8'd0) busy <= busy - 1'b1;
            end
            wire rng_en = pick | (busy != 8'd0);
            localparam RNDT = RND_W + (SPLIT ? XW : 0) + ZACT;
            wire [RNDT-1:0] rnd;
            rng_bank #(.W(RNDT), .SEED(SEED + k)) u_rng (
                .clk(clk), .reset_n(reset_n), .en(rng_en), .rnd(rnd));

            wire           rv;
            wire [CIW-1:0] rtag;
            wire [N-1:0]   rq0, rq1;
            wire           rs0, rs1;
            wire [XW-1:0] x0c, x1c;
            if (SPLIT) begin : g_split
                assign x0c = rnd[RND_W +: XW];                  // fresh mask
                assign x1c = ix0 - x0c;                         // plain value - mask
            end else begin : g_pass
                assign x0c = ix0;
                assign x1c = ix1;
            end

            // this core's constant tables (local column j = global j*NRQ + k)
            wire [NKMAX*BMW-1:0] bm_t;
            wire [NKMAX*MW-1:0]  m0_t;
            wire [NKMAX*SW-1:0]  sh_t;
            for (j = 0; j < NKMAX; j = j + 1) begin : g_tab
                localparam GC = (j < NK) ? j*NRQ + k : k;
                assign bm_t[j*BMW +: BMW] = bm_flat[GC*BMW +: BMW];
                assign m0_t[j*MW +: MW]   = m0_flat[GC*MW +: MW];
                assign sh_t[j*SW +: SW]   = shift_flat[GC*SW +: SW];
            end

            requantize_masked #(
                .N(N), .XW(XW), .MW(MW), .SW(SW), .BMW(BMW), .DOM_REG(DOM_REG),
                .NC(NKMAX), .CIW(CIW)
            ) u_core (
                .clk(clk), .reset_n(reset_n), .valid_in(iv), .col_in(itag),
                .x0_in(x0c), .x1_in(x1c),
                .bm_tab(bm_t), .m0_tab(m0_t), .shift_tab(sh_t), .rnd_in(rnd[RND_W-1:0]),
                .valid_out(rv), .col_out(rtag),
                .q0_out(rq0), .q1_out(rq1), .sat0_out(rs0), .sat1_out(rs1));

            // masked activation on the core's output shares
            activation_unit_masked #(.N(N), .REG(DOM_REG), .TW(CIW)) u_act (
                .clk(clk), .reset_n(reset_n),
                .mode(act_mode), .clamp_high(act_clamp_high), .leaky_shift(act_leaky_shift),
                .valid_in(rv), .tag_in(rtag),
                .x0({N{rv}} & rq0), .x1({N{rv}} & rq1), .st0(rv & rs0), .st1(rv & rs1),   // zeros between values
                .z(rnd[RNDT-ZACT +: ZACT]),
                .valid_out(cv[k]), .tag_out(ctag[k]), .y0(cq0[k]), .y1(cq1[k]), .so0(cs0[k]), .so1(cs1[k]));
        end

        // results back to their columns
        for (c = 0; c < COLS; c = c + 1) begin : g_ret
            localparam KC = c % NRQ;
            localparam JC = c / NRQ;
            reg [NRQ-1:0] po;
            integer kk;
            always @* begin
                for (kk = 0; kk < NRQ; kk = kk + 1) po[kk] = pop_k[kk*COLS + c];
            end
            assign pop[c] = |po;
            wire v = cv[KC] && (ctag[KC] == JC);
            assign valid_out[c]       = v;
            assign q0_flat[c*N +: N]  = {N{v}} & cq0[KC];
            assign q1_flat[c*N +: N]  = {N{v}} & cq1[KC];
            assign sat0_flat[c]       = v & cs0[KC];
            assign sat1_flat[c]       = v & cs1[KC];
        end
    endgenerate
endmodule

// Masked activation_unit on two Boolean (XOR) shares, same function as activation_unit;
// mode, clamp_high and leaky_shift are public.
//   y = x ^ (s & t) ^ (g & u), s = sign of x, g = (x > clamp_high), top bit set by the mode
//   PASS: t = 0, u = 0   RELU: t = x   RELU_CLIP: t = x, u = x ^ clamp_high   LEAKY: t = x ^ (x >>> k)
// For clamp_high >= 0, s = 1 implies g = 0, so the two AND terms never overlap. For clamp_high < 0
// RELU_CLIP is "0 if x < 0, else clamp_high" = clamp_high & ~s, linear in the shares of s.
// Latency: REG = 1 -> 1 + clog2(N) (comparator) + 1 (AND layer); REG = 0 -> 1 (output register).
module activation_unit_masked (clk, reset_n, mode, clamp_high, leaky_shift, valid_in, tag_in,
                               x0, x1, st0, st1, z, valid_out, tag_out, y0, y1, so0, so1);
    parameter N   = 8;
    parameter REG = 1;
    parameter TW  = 1;                        // public tag carried alongside (core column index)
    `include "msk_counts.vh"
    localparam ZC = mskf_cout_z(N);           // comparator random bits
    localparam ZW = ZC + 2*(N-1);
    localparam LC = REG ? 1 + $clog2(N) : 0;  // comparator latency

    input  wire                 clk, reset_n;
    input  wire [1:0]           mode;
    input  wire signed [N-1:0]  clamp_high;
    input  wire [2:0]           leaky_shift;
    input  wire                 valid_in;
    input  wire [TW-1:0]        tag_in;
    input  wire [N-1:0]         x0, x1;
    input  wire                 st0, st1;     // requantizer saturation flag shares
    input  wire [ZW-1:0]        z;
    output wire                 valid_out;
    output wire [TW-1:0]        tag_out;
    output wire [N-1:0]         y0, y1;
    output wire                 so0, so1;

    // g: carry-out of x + ~clamp_high, i.e. x > clamp_high (with the sign bits added below)
    wire co0, co1;
    msk_cout_tree #(.N(N), .REG(REG)) u_cmp (.clk(clk),
        .a0(x0), .a1(x1), .b0(~clamp_high), .b1({N{1'b0}}),
        .z(z[0 +: ZC]), .c0(co0), .c1(co1));

    // shares, sat flags, valid and tag delayed to the comparator output
    localparam DW = 2*N + 2 + TW;
    wire [DW-1:0] dd;
    wire          vd;
    generate
        if (LC == 0) begin : g_nd
            assign dd = {x0, x1, st0, st1, tag_in};
            assign vd = valid_in;
        end else begin : g_d
            reg [DW-1:0] dl [0:LC-1];
            reg [LC-1:0] vl;
            integer i;
            always @(posedge clk) begin
                dl[0] <= {x0, x1, st0, st1, tag_in};
                for (i = 1; i < LC; i = i + 1) dl[i] <= dl[i-1];
                vl <= reset_n ? {vl, valid_in} : {LC{1'b0}};
            end
            assign dd = dl[LC-1];
            assign vd = vl[LC-1];
        end
    endgenerate
    wire [N-1:0]  xd0 = dd[DW-1 -: N];
    wire [N-1:0]  xd1 = dd[DW-1-N -: N];
    wire          sd0 = dd[TW+1], sd1 = dd[TW];
    wire [TW-1:0] tgd = dd[TW-1:0];

    wire g0 = xd0[N-1] ^ clamp_high[N-1] ^ co0;
    wire g1 = xd1[N-1] ^ co1;

    wire relu = (mode == 2'd1) || (mode == 2'd2);
    wire clip = (mode == 2'd2);
    wire lky  = (mode == 2'd3);
    wire [N-1:0] lk0 = $signed(xd0) >>> leaky_shift;          // arithmetic shift is linear on shares
    wire [N-1:0] lk1 = $signed(xd1) >>> leaky_shift;
    wire [N-2:0] t0 = relu ? xd0[N-2:0] : (lky ? (xd0[N-2:0] ^ lk0[N-2:0]) : {(N-1){1'b0}});
    wire [N-2:0] t1 = relu ? xd1[N-2:0] : (lky ? (xd1[N-2:0] ^ lk1[N-2:0]) : {(N-1){1'b0}});
    wire [N-2:0] u0 = clip ? (xd0[N-2:0] ^ clamp_high[N-2:0]) : {(N-1){1'b0}};
    wire [N-2:0] u1 = clip ? xd1[N-2:0] : {(N-1){1'b0}};

    wire [N-2:0] a0, a1, b0, b1;
    dom_and_v #(.W(N-1), .REG(REG)) u_st (.clk(clk), .a0({(N-1){xd0[N-1]}}), .a1({(N-1){xd1[N-1]}}),
        .b0(t0), .b1(t1), .z(z[ZC +: N-1]), .q0(a0), .q1(a1));
    dom_and_v #(.W(N-1), .REG(REG)) u_gu (.clk(clk), .a0({(N-1){g0}}), .a1({(N-1){g1}}),
        .b0(u0), .b1(u1), .z(z[ZC+N-1 +: N-1]), .q0(b0), .q1(b1));

    // linear part, aligned with the AND layer (one register stage in both cases)
    reg [N-1:0]  xe0, xe1;
    reg          se0, se1, ve, re, ce;
    reg [TW-1:0] tge;
    always @(posedge clk) begin
        xe0 <= xd0; xe1 <= xd1; se0 <= sd0; se1 <= sd1; tge <= tgd; re <= relu;
        ce  <= clip & clamp_high[N-1];
        ve  <= reset_n ? vd : 1'b0;
    end
    wire [N-2:0] ab0, ab1;                    // AND layer output, aligned with xe
    generate
        if (REG) begin : g_ro
            assign ab0 = a0 ^ b0;
            assign ab1 = a1 ^ b1;
        end else begin : g_co
            // REG = 0: AND layer is combinational, registered here together with the linear part
            reg [N-2:0] abq0, abq1;
            always @(posedge clk) begin abq0 <= a0 ^ b0; abq1 <= a1 ^ b1; end
            assign ab0 = abq0;
            assign ab1 = abq1;
        end
    endgenerate
    wire [N-1:0] yn0 = {re ? 1'b0 : xe0[N-1], xe0[N-2:0] ^ ab0};
    wire [N-1:0] yn1 = {re ? 1'b0 : xe1[N-1], xe1[N-2:0] ^ ab1};
    wire [N-1:0] yc0 = clamp_high ^ ({N{xe0[N-1]}} & clamp_high);  // clamp_high < 0: clamp_high & ~s
    wire [N-1:0] yc1 = {N{xe1[N-1]}} & clamp_high;
    assign y0 = ce ? yc0 : yn0;
    assign y1 = ce ? yc1 : yn1;
    assign valid_out = ve;
    assign tag_out   = tge;
    assign so0       = se0;
    assign so1       = se1;
endmodule

// Masked maxpool_unit on two Boolean (XOR) shares, same function as maxpool_unit; win_len is public.
// Each element is folded into the running max r as r ^= (x > r) & (x ^ r), with x > r taken from the
// carry of x + ~r (masked carry tree). One element takes 2 + LC + REG cycles; a FIFO of FD entries
// absorbs elements that arrive back to back.
module maxpool_unit_masked (clk, reset_n, valid_in, win_len, x0, x1, z, valid_out, y0, y1, busy);
    parameter N   = 8;
    parameter CW  = 5;
    parameter REG = 1;
    parameter FD  = 4;                        // FIFO depth (elements per column per tile is enough)
    `include "msk_counts.vh"
    localparam ZC  = mskf_cout_z(N);
    localparam ZW  = ZC + N;
    localparam LC  = REG ? 1 + $clog2(N) : 0;
    localparam P   = 1 + LC + REG;            // pop -> running-max update
    localparam FAW = (FD > 1) ? $clog2(FD) : 1;

    input  wire          clk, reset_n, valid_in;
    input  wire [CW-1:0] win_len;
    input  wire [N-1:0]  x0, x1;
    input  wire [ZW-1:0] z;
    output reg           valid_out;
    output reg  [N-1:0]  y0, y1;
    output wire          busy;                // elements queued or being compared (random bits in use)

    // input FIFO
    reg [2*N-1:0] fb [0:FD-1];
    reg [FAW-1:0] wp, rp;
    reg [FAW:0]   fc;
    wire [N-1:0]  h0 = fb[rp][N-1:0];
    wire [N-1:0]  h1 = fb[rp][2*N-1:N];

    // running max, element under comparison, compare pipeline
    reg  [N-1:0]  r0, r1, e0, e1;
    reg  [P-1:0]  ph;
    reg           e_last;
    reg  [CW-1:0] cnt, r_len;
    reg           in_window;
    wire [CW-1:0] l_eff = in_window ? r_len : win_len;
    wire          last  = (cnt == (l_eff - 1'b1));
    wire          free  = ((ph & ~({{(P-1){1'b0}}, 1'b1} << (P-1))) == 0);   // only the update cycle may overlap
    wire          pop   = (fc != 0) && free;
    assign busy = (fc != 0) || (ph != 0) || valid_in;

    wire co0, co1;
    msk_cout_tree #(.N(N), .REG(REG)) u_cmp (.clk(clk),
        .a0(e0), .a1(e1), .b0(~r0), .b1(r1), .z(z[0 +: ZC]), .c0(co0), .c1(co1));
    wire g0 = e0[N-1] ^ r0[N-1] ^ co0;                             // x > r
    wire g1 = e1[N-1] ^ r1[N-1] ^ co1;
    wire [N-1:0] d0, d1;
    dom_and_v #(.W(N), .REG(REG)) u_sel (.clk(clk), .a0({N{g0}}), .a1({N{g1}}),
        .b0(e0 ^ r0), .b1(e1 ^ r1), .z(z[ZC +: N]), .q0(d0), .q1(d1));
    wire [N-1:0] n0 = r0 ^ d0;                                     // updated max
    wire [N-1:0] n1 = r1 ^ d1;

    always @(posedge clk) begin
        if (!reset_n) begin
            wp <= {FAW{1'b0}}; rp <= {FAW{1'b0}}; fc <= {(FAW+1){1'b0}};
            ph <= {P{1'b0}}; cnt <= {CW{1'b0}}; r_len <= {CW{1'b0}}; in_window <= 1'b0;
            valid_out <= 1'b0; e_last <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            if (valid_in) begin
                fb[wp] <= {x1, x0};
                wp <= (wp == FD-1) ? {FAW{1'b0}} : wp + 1'b1;
            end
            if (pop) rp <= (rp == FD-1) ? {FAW{1'b0}} : rp + 1'b1;
            fc <= fc + valid_in - pop;
            ph <= {ph, pop & in_window};                           // first element needs no compare
            if (ph[P-1]) begin
                r0 <= n0; r1 <= n1;
                if (e_last) begin y0 <= n0; y1 <= n1; valid_out <= 1'b1; end
            end
            if (pop) begin
                if (!in_window) r_len <= l_eff;
                e0 <= h0; e1 <= h1; e_last <= last;
                if (!in_window) begin                              // window start: max = element
                    r0 <= h0; r1 <= h1;
                    if (last) begin y0 <= h0; y1 <= h1; valid_out <= 1'b1; end
                end
                if (last) begin cnt <= {CW{1'b0}}; in_window <= 1'b0; end
                else      begin cnt <= cnt + 1'b1; in_window <= 1'b1; end
            end
        end
    end
`ifndef SYNTHESIS
    always @(posedge clk)
        if (reset_n && valid_in && fc == FD && !pop)
            $display("[MPM] ERROR: maxpool FIFO overflowed at t=%0t", $time);
`endif
endmodule
