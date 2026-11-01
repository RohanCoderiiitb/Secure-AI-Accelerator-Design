//=====================================================================
// maxpool_masked.sv -- exact masked equivalent of maxpool_unit
//
// The baseline keeps a running max in a ONE-cycle feedback loop. A masked
// signed compare takes gt_lat(N) cycles, which would break that recurrence
// for back-to-back elements. So the window elements are buffered (Boolean
// shares) and, when the window's LAST element arrives, a pipelined
// TOURNAMENT of masked comparators computes the max (no feedback, a new
// window can start every cycle). The window/length control is the baseline's
// logic verbatim (cnt, r_len, in_window, last) -- it depends only on valid_in
// and win_len, never on data.
//   node:  gt = (a > b);  out = b ^ (gt & (a ^ b))
//   leaves beyond the window length are MOST_NEG constants (shares (0x80, 0)).
// Latency mp_lat(N,CW) = CW * (gt_lat + 1) + 1 register stages after the
// last element. 2^CW leaves cover the baseline's longest window (win_len=0
// wraps to 2^CW elements).
//=====================================================================
module maxpool_masked #(
    parameter N  = 8,
    parameter CW = 5,
    parameter RB = masked_pkg::mp_rnd(N, CW)
) (
    input  wire          clk,
    input  wire          reset_n,
    input  wire          valid_in,
    input  wire [CW-1:0] win_len,
    input  wire [N-1:0]  x0, x1,
    input  wire [RB-1:0] rnd,
    output wire          valid_out,
    output reg  [N-1:0]  y0, y1
);
    localparam LM   = 1 << CW;
    localparam LG   = masked_pkg::gt_lat(N);
    localparam GRB  = masked_pkg::gt_rnd(N);
    localparam NRB  = GRB + N;
    localparam LAT  = CW * (LG + 1) + 1;

    // ---------------- control: identical to maxpool_unit ----------------
    reg [CW-1:0] cnt, r_len;
    reg          in_window;
    wire [CW-1:0] l_eff = in_window ? r_len : win_len;
    wire          last  = (cnt == (l_eff - 1'b1));

    always @(posedge clk) begin
        if (!reset_n) begin
            cnt <= {CW{1'b0}}; r_len <= {CW{1'b0}}; in_window <= 1'b0;
        end else if (valid_in) begin
            if (!in_window) r_len <= l_eff;
            if (last) begin cnt <= {CW{1'b0}}; in_window <= 1'b0; end
            else      begin cnt <= cnt + 1'b1; in_window <= 1'b1;  end
        end
    end

    // ---------------- window buffer (Boolean shares) ----------------
    reg [N-1:0] buf0 [0:LM-1];
    reg [N-1:0] buf1 [0:LM-1];
    integer bi;
    initial for (bi = 0; bi < LM; bi = bi + 1) begin buf0[bi] = 0; buf1[bi] = 0; end
    always @(posedge clk) begin
        if (valid_in && !last) begin
            buf0[cnt] <= x0;
            buf1[cnt] <= x1;
        end
    end

    // ---------------- leaves: buffered < cnt, current == cnt, MOST_NEG above ----------------
    wire [N-1:0] V0 [0:CW][0:LM-1];
    wire [N-1:0] V1 [0:CW][0:LM-1];
    localparam [N-1:0] NEG = {1'b1, {(N-1){1'b0}}};
    genvar i, l, k;
    generate
        for (i = 0; i < LM; i = i + 1) begin : g_leaf
            assign V0[0][i] = (cnt > i) ? buf0[i] : ((cnt == i) ? x0 : NEG);
            assign V1[0][i] = (cnt > i) ? buf1[i] : ((cnt == i) ? x1 : {N{1'b0}});
        end
    endgenerate

    // ---------------- pipelined tournament ----------------
    generate
        for (l = 0; l < CW; l = l + 1) begin : g_lvl
            localparam NN = LM >> (l + 1);                       // nodes at this level
            localparam BASE_ID = LM - (LM >> l);                 // nodes in all lower levels
            for (k = 0; k < NN; k = k + 1) begin : g_node
                localparam OFF = (BASE_ID + k) * NRB;
                wire [N-1:0] a0 = V0[l][2*k],     a1 = V1[l][2*k];
                wire [N-1:0] b0 = V0[l][2*k+1],   b1 = V1[l][2*k+1];
                wire         g0, g1;
                masked_gt #(.N(N)) u_gt (.clk(clk), .a0(a0), .a1(a1), .b0(b0), .b1(b1),
                                         .rnd(rnd[OFF +: GRB]), .gt0(g0), .gt1(g1));
                wire [N-1:0] ab0, ab1, bd0, bd1, z0, z1;
                delay_line #(.W(N), .D(LG))   u_ab0 (.clk(clk), .d(a0 ^ b0), .q(ab0));
                delay_line #(.W(N), .D(LG))   u_ab1 (.clk(clk), .d(a1 ^ b1), .q(ab1));
                delay_line #(.W(N), .D(LG+1)) u_bd0 (.clk(clk), .d(b0), .q(bd0));
                delay_line #(.W(N), .D(LG+1)) u_bd1 (.clk(clk), .d(b1), .q(bd1));
                dom_and #(.W(N)) u_mux (.clk(clk), .x0({N{g0}}), .x1({N{g1}}), .y0(ab0), .y1(ab1),
                                        .r(rnd[OFF + GRB +: N]), .z0(z0), .z1(z1));
                assign V0[l+1][k] = bd0 ^ z0;
                assign V1[l+1][k] = bd1 ^ z1;
            end
            // unused upper slots of this level's array (keep the net driven)
            for (k = NN; k < LM; k = k + 1) begin : g_pad
                assign V0[l+1][k] = {N{1'b0}};
                assign V1[l+1][k] = {N{1'b0}};
            end
        end
    endgenerate

    always @(posedge clk) begin
        y0 <= V0[CW][0];
        y1 <= V1[CW][0];
    end
    delay_line #(.W(1), .D(LAT)) u_v (.clk(clk), .d(valid_in & last), .q(valid_out));
endmodule
