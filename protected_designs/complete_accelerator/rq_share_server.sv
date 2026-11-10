// NRQ masked requantizer cores shared round-robin by COLS columns
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

    // per-column share buffer
    wire [COLS-1:0]    nonempty;
    wire [COLS-1:0]    pop;
    wire [XW-1:0]      head0 [0:COLS-1];
    wire [XW-1:0]      head1 [0:COLS-1];

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
                        b0[wp*XW +: XW] <= x0_flat[c*XW +: XW];
                        if (!SPLIT) b1[wp*XW +: XW] <= x1_flat[c*XW +: XW];
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
                if (pick) begin
                    itag <= sel;
                    ix0  <= head0[sel*NRQ + k];
                    ix1  <= head1[sel*NRQ + k];
                end
            end

            // randomness
            reg [7:0] busy;
            always @(posedge clk) begin
                if (!reset_n)          busy <= 8'd0;
                else if (pick)         busy <= LAT + 2;
                else if (busy != 8'd0) busy <= busy - 1'b1;
            end
            wire rng_en = pick | (busy != 8'd0);
            localparam RNDT = RND_W + (SPLIT ? XW : 0);
            wire [RNDT-1:0] rnd;
            rng_bank #(.W(RNDT), .SEED(SEED + k)) u_rng (
                .clk(clk), .reset_n(reset_n), .en(rng_en), .rnd(rnd));

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
                .valid_out(cv[k]), .col_out(ctag[k]),
                .q0_out(cq0[k]), .q1_out(cq1[k]), .sat0_out(cs0[k]), .sat1_out(cs1[k]));
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
