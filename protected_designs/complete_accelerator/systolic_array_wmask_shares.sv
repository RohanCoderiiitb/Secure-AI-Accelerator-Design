//=====================================================================
// systolic_array_wmask_shares.sv -- weight-masked array that hands its
//                                    result out as TWO SHARES
//
// Identical to systolic_array_wmask_shared (protected_designs/source)
// except there is no recombination adder at the bottom: each column
// outputs
//     psum0 = masked partial sum   sum_r a_r*(w_rc - R_r)
//     psum1 = shadow correction    sum_r a_r*R_r   (delayed by c cycles)
// with psum0 + psum1 = real column sum (mod 2^SW). Each share alone is
// independent of the weights, so the masked accumulator / requantizer
// can consume them directly: no extra masker, no extra randomness.
//
// Reuses wmask_gen, processing_element_wshare, shadow_pe and
// wsm_share_multiplier from systolic_array_wmask_shared.sv.
//=====================================================================
module systolic_array_wmask_shares #(
    parameter N    = 8,
    parameter ROWS = 5,
    parameter COLS = 5,
    parameter SW   = 2*N + $clog2(ROWS),
    parameter [63:0] MASK_SEED = 64'h9E3779B97F4A7C15
) (
    input  wire                  clk,
    input  wire                  reset_n,
    input  wire                  mask_en,
    input  wire                  mask_refresh,
    input  wire                  wt_load,
    input  wire [COLS*N-1:0]     wt_flat,
    input  wire [ROWS-1:0]       valid_act_in,
    input  wire [ROWS*N-1:0]     act_flat,
    output wire [COLS*SW-1:0]    psum0_out,
    output wire [COLS*SW-1:0]    psum1_out,
    output wire [COLS-1:0]       valid_sum_out,
    output wire [ROWS*N-1:0]     act_out,
    output wire [ROWS-1:0]       valid_act_out
);
    // ---------------- masks ----------------
    wire [ROWS*SW-1:0] r_flat;
    wmask_gen #(.SW(SW), .ROWS(ROWS), .SEED(MASK_SEED)) u_mgen (
        .clk(clk), .reset_n(reset_n), .refresh(mask_refresh),
        .mask_en(mask_en), .r_flat(r_flat));

    wire [SW-1:0] R [0:ROWS-1];
    genvar r, c;
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_r
            assign R[r] = r_flat[r*SW +: SW];
        end
    endgenerate

    // ---------------- north-edge masking (load step k -> row ROWS-1-k) ----------------
    localparam CW = (ROWS > 1) ? $clog2(ROWS) : 1;
    reg [CW-1:0] ld_cnt;
    // counts wt_load PULSES (gaps between pulses are allowed, as with the
    // load controller); restarts on every mask refresh
    always @(posedge clk) begin
        if (!reset_n || mask_refresh)            ld_cnt <= {CW{1'b0}};
        else if (wt_load && ld_cnt != ROWS-1)    ld_cnt <= ld_cnt + 1'b1;
    end
    wire [SW-1:0] r_sel = R[ROWS-1-ld_cnt];

    wire signed [N-1:0] act [0:ROWS-1][0:COLS];
    wire                vld [0:ROWS-1][0:COLS];
    wire [SW-1:0]       ps  [0:ROWS][0:COLS-1];
    wire [SW-1:0]       wt1 [0:ROWS][0:COLS-1];

    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_west
            assign act[r][0]         = act_flat[r*N +: N];
            assign vld[r][0]         = valid_act_in[r];
            assign act_out[r*N +: N] = act[r][COLS];
            assign valid_act_out[r]  = vld[r][COLS];
        end
        for (c = 0; c < COLS; c = c + 1) begin : g_entry
            wire signed [N-1:0] w_plain = wt_flat[c*N +: N];
            wire [SW-1:0]       w_ext   = {{(SW-N){w_plain[N-1]}}, w_plain};
            assign wt1[0][c] = w_ext - r_sel;
            assign ps[0][c]  = {SW{1'b0}};                    // single tile
        end
    endgenerate

    // ---------------- PE grid ----------------
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                wire                pe_valid_out;
                wire [SW-1:0]       pe_wt_out;
                wire signed [N-1:0] pe_act_out;
                wire [SW-1:0]       pe_psum_out;

                (* dont_touch = "yes", keep_hierarchy = "yes" *)
                processing_element_wshare #(.N(N), .SW(SW)) pe_inst (
                    .clk(clk), .reset_n(reset_n), .wt_load(wt_load),
                    .wt_in(wt1[r][c]), .valid_in(vld[r][c]),
                    .act_in(act[r][c]), .psum_in(ps[r][c]),
                    .valid_out(pe_valid_out), .wt_out(pe_wt_out),
                    .act_out(pe_act_out), .psum_out(pe_psum_out));

                assign act[r][c+1] = pe_act_out;
                assign vld[r][c+1] = pe_valid_out;
                assign wt1[r+1][c] = pe_wt_out;
                assign ps[r+1][c]  = pe_psum_out;
            end
        end
    endgenerate

    // ---------------- shadow column: S = sum_r a_r*R_r ----------------
    wire [SW-1:0] sh [0:ROWS];
    assign sh[0] = {SW{1'b0}};
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_shadow
            (* dont_touch = "yes", keep_hierarchy = "yes" *)
            shadow_pe #(.N(N), .SW(SW)) sh_inst (
                .clk(clk), .reset_n(reset_n), .r_mask(R[r]),
                .act_in(act[r][0]), .psum_in(sh[r]), .psum_out(sh[r+1]));
        end
    endgenerate

    wire [SW-1:0] s_col [0:COLS-1];
    assign s_col[0] = sh[ROWS];
    generate
        for (c = 1; c < COLS; c = c + 1) begin : g_dly
            reg [SW-1:0] d;
            always @(posedge clk) begin
                if (!reset_n) d <= {SW{1'b0}};
                else          d <= s_col[c-1];
            end
            assign s_col[c] = d;
        end
    endgenerate

    // ---------------- outputs: two shares, no recombination ----------------
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_out
            assign psum0_out[c*SW +: SW] = ps[ROWS][c];
            assign psum1_out[c*SW +: SW] = s_col[c];
            assign valid_sum_out[c]      = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule
