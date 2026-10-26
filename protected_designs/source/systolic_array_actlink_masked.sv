//=====================================================================
// systolic_array_actlink_masked.sv -- ROWS x COLS array of the UNMODIFIED
// baseline processing_element (plain multiplier, plain weights, plain
// psums). All masking lives in the ARRAY, on the west->east activation
// links.
//
// External interface = baseline systolic_array plus
//     mask_en   1: fresh additive mask per row every cycle
//               0: positive control (share0 = 0, share1 = A)
//
// Structure per row (east-flowing activation path):
//   act_masker (west boundary) -> shares
//   act_link_masked[0]          recombine only         -> PE col 0 act_in
//   act_link_masked[c], c >= 1  share registers + recombine -> PE col c act_in
//   act_link_masked[COLS]       share registers + recombine -> act_out
// The PE's own act_out register is NOT used for the link (left open), so
// between PEs the activation is held and moved only as two shares; each PE
// receives the recombined value for its plain multiplier.
//
// Cycle-for-cycle identical outputs to systolic_array for any mask_en.
// Needs baugh_wooley_multiplier + processing_element (source/), act_masker.sv.
// For TVLA dump the PEs and the act_link_masked instances, NOT the masker.
//=====================================================================
module act_link_masked #(
    parameter N          = 8,
    parameter SHARE_W    = N,
    parameter REGISTERED = 1
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire [SHARE_W-1:0]   a0_in,
    input  wire [SHARE_W-1:0]   a1_in,
    output wire [SHARE_W-1:0]   a0_q,        // shares, one hop later (== a0_in if !REGISTERED)
    output wire [SHARE_W-1:0]   a1_q,
    output wire signed [N-1:0]  act_plain    // recombined, feeds the plain PE
);
    generate
        if (REGISTERED) begin : g_reg
            reg [SHARE_W-1:0] r0, r1;
            always @(posedge clk) begin
                if (!reset_n) begin r0 <= {SHARE_W{1'b0}}; r1 <= {SHARE_W{1'b0}}; end
                else          begin r0 <= a0_in;           r1 <= a1_in;           end
            end
            assign a0_q = r0;
            assign a1_q = r1;
        end else begin : g_wire
            assign a0_q = a0_in;
            assign a1_q = a1_in;
        end
    endgenerate
    assign act_plain = a0_q[N-1:0] + a1_q[N-1:0];
endmodule

module systolic_array_actlink_masked #(
    parameter N              = 8,
    parameter ACCW           = 32,
    parameter ROWS           = 5,
    parameter COLS           = 5,
    parameter SHARE_W        = N,
    parameter [63:0] MASK_SEED = 64'd1
) (
    input  wire                  clk,
    input  wire                  reset_n,
    input  wire                  mask_en,
    input  wire                  wt_load,
    input  wire [COLS*N-1:0]     wt_flat,
    input  wire [ROWS-1:0]       valid_act_in,
    input  wire [ROWS*N-1:0]     act_flat,
    input  wire [COLS*ACCW-1:0]  psum_flat,
    output wire [COLS*ACCW-1:0]  psum_out,
    output wire [COLS-1:0]       valid_sum_out,
    output wire [ROWS*N-1:0]     act_out,
    output wire [ROWS-1:0]       valid_act_out
);
    wire [ROWS*SHARE_W-1:0] m_a0, m_a1;
    act_masker #(.N(N), .SHARE_W(SHARE_W), .ROWS(ROWS), .SEED(MASK_SEED)) u_masker (
        .clk(clk), .reset_n(reset_n), .advance(1'b1), .mask_en(mask_en),
        .act_flat(act_flat), .act0_flat(m_a0), .act1_flat(m_a1));

    wire [SHARE_W-1:0]     s0   [0:ROWS-1][0:COLS];   // shares leaving link c
    wire [SHARE_W-1:0]     s1   [0:ROWS-1][0:COLS];
    wire signed [N-1:0]    actp [0:ROWS-1][0:COLS];   // recombined value at link c
    wire                   vld  [0:ROWS-1][0:COLS];
    wire signed [ACCW-1:0] psum [0:ROWS][0:COLS-1];
    wire signed [N-1:0]    wt   [0:ROWS][0:COLS-1];

    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_west
            assign vld[r][0]         = valid_act_in[r];
            assign act_out[r*N +: N] = actp[r][COLS];
            assign valid_act_out[r]  = vld[r][COLS];
        end
        for (c = 0; c < COLS; c = c + 1) begin : g_north
            assign wt[0][c]   = wt_flat[c*N +: N];
            assign psum[0][c] = psum_flat[c*ACCW +: ACCW];
            assign psum_out[c*ACCW +: ACCW] = psum[ROWS][c];
        end
    endgenerate

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c <= COLS; c = c + 1) begin : g_lnk
                if (c == 0) begin : g_first
                    act_link_masked #(.N(N), .SHARE_W(SHARE_W), .REGISTERED(0)) u_link (
                        .clk(clk), .reset_n(reset_n),
                        .a0_in(m_a0[r*SHARE_W +: SHARE_W]), .a1_in(m_a1[r*SHARE_W +: SHARE_W]),
                        .a0_q(s0[r][0]), .a1_q(s1[r][0]), .act_plain(actp[r][0]));
                end else begin : g_next
                    act_link_masked #(.N(N), .SHARE_W(SHARE_W), .REGISTERED(1)) u_link (
                        .clk(clk), .reset_n(reset_n),
                        .a0_in(s0[r][c-1]), .a1_in(s1[r][c-1]),
                        .a0_q(s0[r][c]), .a1_q(s1[r][c]), .act_plain(actp[r][c]));
                end
            end
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                wire                   pe_valid_out;
                wire signed [N-1:0]    pe_wt_out;
                wire signed [ACCW-1:0] pe_psum_out;

                (* dont_touch = "yes" *)
                processing_element #(.N(N), .ACCW(ACCW)) pe_inst (
                    .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
                    .wt_in(wt[r][c]), .valid_in(vld[r][c]),
                    .act_in(actp[r][c]), .psum_in(psum[r][c]),
                    .valid_out(pe_valid_out), .wt_out(pe_wt_out),
                    .act_out(),                       // link carried by act_link_masked
                    .psum_out(pe_psum_out));

                assign vld[r][c+1]  = pe_valid_out;
                assign wt[r+1][c]   = pe_wt_out;
                assign psum[r+1][c] = pe_psum_out;
            end
        end
    endgenerate

    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_south_valid
            assign valid_sum_out[c] = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule
