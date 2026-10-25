// Baugh-Wooley Multiplier with both weights, and activations masked
// Arithmetic masking

// module share_multiplier #(
//     parameter N  = 8,
//     parameter SW = 2*N
// ) (
//     input  wire [N-1:0]  a,
//     input  wire [SW-1:0] ws,
//     output wire [SW-1:0] p
// );
//     // ---- partial-product rows (SW bits each) ----
//     wire [SW-1:0] row [0:N-1];

//     genvar i, k;
//     generate
//         for (i = 0; i < N; i = i + 1) begin : g_row
//             for (k = 0; k < SW; k = k + 1) begin : g_bit
//                 if (k < i) begin : g_zero
//                     assign row[i][k] = 1'b0;                     // shifted-in zeros
//                 end else if (i == N-1) begin : g_sign
//                     assign row[i][k] = ~(a[i] & ws[k-i]);        // flipped sign row
//                 end else begin : g_pp
//                     assign row[i][k] = a[i] & ws[k-i];
//                 end
//             end
//         end
//     endgenerate

//     // ---- carry-save array ----
//     // s[i] / c[i] = sum and carry vectors after adding rows 0..i.
//     // A carry c[i][k] has weight 2^(k+1), so it enters column k+1 of the next row.
//     wire [SW-1:0] s [0:N-1];
//     wire [SW-1:0] c [0:N-1];

//     assign s[0] = row[0];
//     // +1 at bit N-1 for the flipped sign row: a carry at position N-2 has weight 2^(N-1)
//     assign c[0] = {{(SW-1){1'b0}}, 1'b1} << (N-2);

//     generate
//         for (i = 1; i < N; i = i + 1) begin : g_csa_row
//             for (k = 0; k < SW; k = k + 1) begin : g_csa_col
//                 if (k == 0) begin : g_ha
//                     half_adder u_ha (
//                         .a   (row[i][0]),
//                         .b   (s[i-1][0]),
//                         .s   (s[i][0]),
//                         .cout(c[i][0])
//                     );
//                 end else begin : g_fa
//                     full_adder u_fa (
//                         .a   (row[i][k]),
//                         .b   (s[i-1][k]),
//                         .cin (c[i-1][k-1]),
//                         .s   (s[i][k]),
//                         .cout(c[i][k])            // c[i][SW-1] is dropped (mod 2^SW)
//                     );
//                 end
//             end
//         end
//     endgenerate

//     // ---- vector-merge adder: p = s[N-1] + (c[N-1] << 1)  mod 2^SW ----
//     wire [SW:0] rc;
//     assign rc[1] = 1'b0;
//     assign p[0]  = s[N-1][0];

//     generate
//         for (k = 1; k < SW; k = k + 1) begin : g_vma
//             full_adder u_vma (
//                 .a   (s[N-1][k]),
//                 .b   (c[N-1][k-1]),
//                 .cin (rc[k]),
//                 .s   (p[k]),
//                 .cout(rc[k+1])                    // rc[SW] is dropped (mod 2^SW)
//             );
//         end
//     endgenerate
// endmodule

module masked_multiplier_aw #(
    parameter N  = 8,
    parameter SW = 2*N
) (
    input  wire          clk,
    input  wire          reset_n,

    // weight shares (same scheme as masked_weight_multiplier)
    input  wire          w_load,
    input  wire [SW-1:0] w0_in,
    input  wire [SW-1:0] w1_in,
    input  wire          refresh_en,
    input  wire [SW-1:0] r_refresh,     // fresh every cycle

    // activation shares, made outside: m random, a0 = sext(a) - m, a1 = m
    input  wire [SW-1:0] a0,
    input  wire [SW-1:0] a1,

    // fresh random for the cross terms, every cycle
    input  wire [SW-1:0] r_cross,

    output wire [SW-1:0] p0,            // p0 + p1 = a*w (mod 2^SW)
    output wire [SW-1:0] p1
);
    // ---------------- weight shares with refresh ----------------
    reg [SW-1:0] w0_reg;
    reg [SW-1:0] w1_reg;

    always @(posedge clk) begin
        if (!reset_n) begin
            w0_reg <= {SW{1'b0}};
            w1_reg <= {SW{1'b0}};
        end else if (w_load) begin
            w0_reg <= w0_in;
            w1_reg <= w1_in;
        end else if (refresh_en) begin
            w0_reg <= w0_reg - r_refresh;
            w1_reg <= w1_reg + r_refresh;
        end
    end

    // ---------------- four share products, mod 2^SW ----------------
    // share_multiplier with N = SW multiplies two SW-bit values and keeps the
    // low SW bits; mod 2^SW the signedness of the operands does not matter.
    wire [SW-1:0] m00, m11, m01, m10;

    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(SW), .SW(SW)) u_m00 (.a(a0), .ws(w0_reg), .p(m00));  // inner, domain 0
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(SW), .SW(SW)) u_m11 (.a(a1), .ws(w1_reg), .p(m11));  // inner, domain 1
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(SW), .SW(SW)) u_m01 (.a(a0), .ws(w1_reg), .p(m01));  // cross
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(SW), .SW(SW)) u_m10 (.a(a1), .ws(w0_reg), .p(m10));  // cross

    // ---------------- blind cross terms, register everything ----------------
    reg [SW-1:0] t00, t11;   // inner terms
    reg [SW-1:0] t01, t10;   // blinded cross terms

    always @(posedge clk) begin
        if (!reset_n) begin
            t00 <= {SW{1'b0}};
            t11 <= {SW{1'b0}};
            t01 <= {SW{1'b0}};
            t10 <= {SW{1'b0}};
        end else begin
            t00 <= m00;
            t11 <= m11;
            t01 <= m01 + r_cross;     // joins domain 0
            t10 <= m10 - r_cross;     // joins domain 1
        end
    end

    // ---------------- compression: one adder per domain ----------------
    assign p0 = t00 + t01;
    assign p1 = t11 + t10;
endmodule