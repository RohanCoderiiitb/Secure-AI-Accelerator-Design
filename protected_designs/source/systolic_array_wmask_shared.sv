//=====================================================================
// systolic_array_wmask_shared.sv -- weight-masked ROWS x COLS array
//                                   with ONE share per PE and a SHARED
//                                   random-weight column
//
// Threat model: weights are secret (model IP), activations are public.
//
// Idea
//   Each weight is split as   w = w1 + R_r   (mod 2^SW)
//   where R_r is a fresh random number per ROW (shared by all columns of
//   that row) and w1 = w - R_r is what the PE stores.
//
//   Column c output   = sum_r a_r * w_rc
//                     = sum_r a_r * w1_rc  +  sum_r a_r * R_r
//                       \_______________/     \____________/
//                        PE grid (masked)      S: identical for every
//                                              column, only delayed by c
//
//   S never touches a secret, so it is computed ONCE in a shadow column
//   (ROWS share multipliers) and delayed by c cycles for column c,
//   instead of doubling the multiplier in all ROWS*COLS PEs.
//
// Blocks
//   u_mgen     xorshift64 mask generator -> R_0..R_{ROWS-1} (shift chain,
//              filled while mask_refresh=1, held otherwise)
//   g_entry    north edge: w1 = sext(w) - R[dest row]   (load counter)
//   g_row/g_col/pe_inst   plain-structure PE, ONE SW-bit share datapath
//   g_shadow/sh_inst      shadow column: a_r * R_r, same timing as col 0
//   g_dly      S delay line, column c sees S delayed by c cycles
//   g_out      per column: psum_out = psum1 + S_c   (only recombination)
//
// Protocol (per weight load / tile)
//   1. mask_refresh = 1 for ROWS cycles   (fresh R; do NOT overlap load)
//   2. wt_load      = 1 for ROWS cycles   (row ROWS-1 driven first, as in
//                                          the baseline)
//   3. stream activations (skew in TB, as in the baseline)
//   mask_en = 0 : R = 0  -> positive control (w1 = w, S = 0), TVLA MUST leak.
//
// External interface = baseline systolic_array + mask_en + mask_refresh.
// psum_out is cycle-for-cycle identical to the baseline for any mask_en.
//
// Needs half_adder / full_adder from source/multiplier.sv. Do NOT also
// compile masked_wt_multiplier.sv (it redefines those adders).
//
// SW >= 2N + clog2(ROWS) (19 for 5x5 INT8). The top-of-column psum_flat
// enters the share chain in the clear; tie it to 0 for single-tile runs.
//
// For TVLA dump g_row[*].g_col[*].pe_inst (and optionally sh_inst /
// g_out). Keep u_mgen and g_entry out of the dump: they see the plain
// weight only during the untriggered load phase, like the act_masker.
//=====================================================================

// ---------------------------------------------------------------------
// p = (a * ws) mod 2^SW, a signed N-bit, ws any SW-bit residue.
// Same Baugh-Wooley CSA structure as share_multiplier, renamed so this
// file can coexist with masked_wt_multiplier.sv in a project.
// ---------------------------------------------------------------------
module wsm_share_multiplier #(
    parameter N  = 8,
    parameter SW = 19
) (
    input  wire [N-1:0]  a,
    input  wire [SW-1:0] ws,
    output wire [SW-1:0] p
);
    wire [SW-1:0] row [0:N-1];
    genvar i, k;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (k = 0; k < SW; k = k + 1) begin : g_bit
                if (k < i) begin : g_zero
                    assign row[i][k] = 1'b0;
                end else if (i == N-1) begin : g_sign
                    assign row[i][k] = ~(a[i] & ws[k-i]);
                end else begin : g_pp
                    assign row[i][k] = a[i] & ws[k-i];
                end
            end
        end
    endgenerate

    wire [SW-1:0] s [0:N-1];
    wire [SW-1:0] c [0:N-1];
    assign s[0] = row[0];
    assign c[0] = {{(SW-1){1'b0}}, 1'b1} << (N-2);   // +2^(N-1) for the flipped sign row

    generate
        for (i = 1; i < N; i = i + 1) begin : g_csa_row
            for (k = 0; k < SW; k = k + 1) begin : g_csa_col
                if (k == 0) begin : g_ha
                    half_adder u_ha (.a(row[i][0]), .b(s[i-1][0]), .s(s[i][0]), .cout(c[i][0]));
                end else begin : g_fa
                    full_adder u_fa (.a(row[i][k]), .b(s[i-1][k]), .cin(c[i-1][k-1]),
                                     .s(s[i][k]), .cout(c[i][k]));
                end
            end
        end
    endgenerate

    wire [SW:0] rc;
    assign rc[1] = 1'b0;
    assign p[0]  = s[N-1][0];
    generate
        for (k = 1; k < SW; k = k + 1) begin : g_vma
            full_adder u_vma (.a(s[N-1][k]), .b(c[N-1][k-1]), .cin(rc[k]),
                              .s(p[k]), .cout(rc[k+1]));
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------
// One-share weight-stationary PE. Same ports/behaviour as the baseline
// processing_element except the weight and psum are SW-bit residues.
// No net in here is a function of the plaintext weight (w1 = w - R_r).
// ---------------------------------------------------------------------
module processing_element_wshare #(
    parameter N  = 8,
    parameter SW = 19
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 wt_load,
    input  wire [SW-1:0]        wt_in,      // masked weight share w1
    input  wire                 valid_in,
    input  wire signed [N-1:0]  act_in,     // public
    input  wire [SW-1:0]        psum_in,    // masked partial sum
    output reg                  valid_out,
    output wire [SW-1:0]        wt_out,
    output reg  signed [N-1:0]  act_out,
    output reg  [SW-1:0]        psum_out
);
    reg [SW-1:0] wt_reg;
    assign wt_out = wt_reg;

    wire [SW-1:0] prod;
    wsm_share_multiplier #(.N(N), .SW(SW)) u_mul (.a(act_in), .ws(wt_reg), .p(prod));

    always @(posedge clk) begin
        if (!reset_n) begin
            valid_out <= 1'b0;
            act_out   <= {N{1'b0}};
            wt_reg    <= {SW{1'b0}};
            psum_out  <= {SW{1'b0}};
        end else begin
            if (wt_load) wt_reg <= wt_in;
            act_out   <= act_in;
            psum_out  <= psum_in + prod;
            valid_out <= valid_in;
        end
    end
endmodule

// ---------------------------------------------------------------------
// Shadow PE: psum_out <= psum_in + act_in * R. Holds no secret.
// No act/valid registers (the shadow column only produces S).
// ---------------------------------------------------------------------
module shadow_pe #(
    parameter N  = 8,
    parameter SW = 19
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire [SW-1:0]        r_mask,
    input  wire signed [N-1:0]  act_in,
    input  wire [SW-1:0]        psum_in,
    output reg  [SW-1:0]        psum_out
);
    wire [SW-1:0] prod;
    wsm_share_multiplier #(.N(N), .SW(SW)) u_mul (.a(act_in), .ws(r_mask), .p(prod));
    always @(posedge clk) begin
        if (!reset_n) psum_out <= {SW{1'b0}};
        else          psum_out <= psum_in + prod;
    end
endmodule

// ---------------------------------------------------------------------
// Mask generator: xorshift64 (no multiply), shift chain of ROWS words.
// While refresh=1, word 0 takes fresh bits and word k takes word k-1;
// ROWS refresh cycles give ROWS independent words. Held otherwise.
// mask_en=0 shifts in zeros (positive control).
// ---------------------------------------------------------------------
module wmask_gen #(
    parameter SW       = 19,
    parameter ROWS     = 5,
    parameter [63:0] SEED = 64'h9E3779B97F4A7C15
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 refresh,
    input  wire                 mask_en,
    output wire [ROWS*SW-1:0]   r_flat
);
    reg  [63:0] x;
    wire [63:0] x1 = x  ^ (x  << 13);
    wire [63:0] x2 = x1 ^ (x1 >> 7);
    wire [63:0] x3 = x2 ^ (x2 << 17);

    reg [SW-1:0] rw [0:ROWS-1];
    integer k;
    always @(posedge clk) begin
        if (!reset_n) begin
            x <= (SEED == 64'd0) ? 64'd1 : SEED;
            for (k = 0; k < ROWS; k = k + 1) rw[k] <= {SW{1'b0}};
        end else begin
            x <= x3;                                  // free-running
            if (refresh) begin
                rw[0] <= mask_en ? x[SW-1:0] : {SW{1'b0}};
                for (k = 1; k < ROWS; k = k + 1) rw[k] <= rw[k-1];
            end
        end
    end
    genvar g;
    generate
        for (g = 0; g < ROWS; g = g + 1) begin : g_out
            assign r_flat[g*SW +: SW] = rw[g];
        end
    endgenerate
endmodule

// ---------------------------------------------------------------------
// Top-level array
// ---------------------------------------------------------------------
module systolic_array_wmask_shared #(
    parameter N    = 8,
    parameter ACCW = 32,
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
    input  wire [COLS*ACCW-1:0]  psum_flat,
    output wire [COLS*ACCW-1:0]  psum_out,
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

    // ---------------- north-edge masking ----------------
    // Load step k (k = 0..ROWS-1) carries the weight for row ROWS-1-k.
    localparam CW = (ROWS > 1) ? $clog2(ROWS) : 1;
    reg [CW-1:0] ld_cnt;
    always @(posedge clk) begin
        if (!reset_n || !wt_load) ld_cnt <= {CW{1'b0}};
        else if (ld_cnt != ROWS-1) ld_cnt <= ld_cnt + 1'b1;
    end
    wire [SW-1:0] r_sel = R[ROWS-1-ld_cnt];

    wire signed [N-1:0]  act  [0:ROWS-1][0:COLS];
    wire                 vld  [0:ROWS-1][0:COLS];
    wire [SW-1:0]        ps   [0:ROWS][0:COLS-1];
    wire [SW-1:0]        wt1  [0:ROWS][0:COLS-1];

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
            assign ps[0][c]  = psum_flat[c*ACCW +: SW];
        end
    endgenerate

    // ---------------- PE grid (one share each) ----------------
    generate
        for (r = 0; r < ROWS; r = r + 1) begin : g_row
            for (c = 0; c < COLS; c = c + 1) begin : g_col
                wire                 pe_valid_out;
                wire [SW-1:0]        pe_wt_out;
                wire signed [N-1:0]  pe_act_out;
                wire [SW-1:0]        pe_psum_out;

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

    // ---------------- shadow column: S = sum_r a_r * R_r ----------------
    // Fed with the same activations as column 0, so it has column 0 timing.
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

    // ---------------- delay line: column c uses S delayed by c ----------------
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

    // ---------------- recombination (only place w appears in the clear) ----------------
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_out
            wire [SW-1:0] y = ps[ROWS][c] + s_col[c];
            assign psum_out[c*ACCW +: ACCW] = {{(ACCW-SW){y[SW-1]}}, y};
            assign valid_sum_out[c] = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule
