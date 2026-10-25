// Baugh-Wooley multiplier with masked weights
// Arithmetic Masking

module half_adder(
    input a, input b, output s, output cout
);
    assign s = a^b;
    assign cout = a&b;
endmodule

module full_adder(
    input a, input b, input cin, output s, output cout
);
    assign s = a^b^cin;
    assign cout = a&b | b&cin | cin&a;
endmodule

// share_multiplier: p = (a * ws) mod 2^SW
// Same Baugh-Wooley idea as the unprotected design
// The "+1" is injected through the initial carry vector c[0].
// Rows are summed with a carry-save array of full adders, everything truncated to SW bits (carries out of bit SW-1 are dropped = mod 2^SW), then a ripple vector-merge adder produces p.
module share_multiplier #(
    parameter N  = 8,
    parameter SW = 2*N
) (
    input  wire [N-1:0]  a,
    input  wire [SW-1:0] ws,
    output wire [SW-1:0] p
);
    // ---- partial-product rows (SW bits each) ----
    wire [SW-1:0] row [0:N-1];

    genvar i, k;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_row
            for (k = 0; k < SW; k = k + 1) begin : g_bit
                if (k < i) begin : g_zero
                    assign row[i][k] = 1'b0;                     // shifted-in zeros
                end else if (i == N-1) begin : g_sign
                    assign row[i][k] = ~(a[i] & ws[k-i]);        // flipped sign row
                end else begin : g_pp
                    assign row[i][k] = a[i] & ws[k-i];
                end
            end
        end
    endgenerate

    // ---- carry-save array ----
    // s[i] / c[i] = sum and carry vectors after adding rows 0..i.
    // A carry c[i][k] has weight 2^(k+1), so it enters column k+1 of the next row.
    wire [SW-1:0] s [0:N-1];
    wire [SW-1:0] c [0:N-1];

    assign s[0] = row[0];
    // +1 at bit N-1 for the flipped sign row: a carry at position N-2 has weight 2^(N-1)
    assign c[0] = {{(SW-1){1'b0}}, 1'b1} << (N-2);

    generate
        for (i = 1; i < N; i = i + 1) begin : g_csa_row
            for (k = 0; k < SW; k = k + 1) begin : g_csa_col
                if (k == 0) begin : g_ha
                    half_adder u_ha (
                        .a   (row[i][0]),
                        .b   (s[i-1][0]),
                        .s   (s[i][0]),
                        .cout(c[i][0])
                    );
                end else begin : g_fa
                    full_adder u_fa (
                        .a   (row[i][k]),
                        .b   (s[i-1][k]),
                        .cin (c[i-1][k-1]),
                        .s   (s[i][k]),
                        .cout(c[i][k])            // c[i][SW-1] is dropped (mod 2^SW)
                    );
                end
            end
        end
    endgenerate

    // ---- vector-merge adder: p = s[N-1] + (c[N-1] << 1)  mod 2^SW ----
    wire [SW:0] rc;
    assign rc[1] = 1'b0;
    assign p[0]  = s[N-1][0];

    generate
        for (k = 1; k < SW; k = k + 1) begin : g_vma
            full_adder u_vma (
                .a   (s[N-1][k]),
                .b   (c[N-1][k-1]),
                .cin (rc[k]),
                .s   (p[k]),
                .cout(rc[k+1])                    // rc[SW] is dropped (mod 2^SW)
            );
        end
    endgenerate
endmodule

// masked_weight_multiplier
// Holds the weight as two arithmetic shares and multiplies each share by the public activation in its own share_multiplier.
// Refresh keeps the sum unchanged: (w0 - r) + (w1 + r) = w0 + w1
// Without it the shares would stay constant for a whole tile, and an
// Attacker could recover w0 and w1 separately with ordinary CPA.
module masked_weight_multiplier #(
    parameter N  = 8,
    parameter SW = 32
) (
    input  wire          clk,
    input  wire          reset_n,
    input  wire          w_load,
    input  wire [SW-1:0] w0_in,
    input  wire [SW-1:0] w1_in,
    input  wire          refresh_en,
    input  wire [SW-1:0] r_refresh,
    input  wire [N-1:0]  a,
    output wire [SW-1:0] p0,
    output wire [SW-1:0] p1
);
    reg [SW-1:0] w0_reg;     // domain-0 weight share
    reg [SW-1:0] w1_reg;     // domain-1 weight share

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

    // Two physically separate share datapaths. dont_touch / keep_hierarchy stop
    // synthesis from merging or restructuring them across the share boundary.
    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SW)) u_dom0 (
        .a  (a),
        .ws (w0_reg),
        .p  (p0)
    );

    (* dont_touch = "yes", keep_hierarchy = "yes" *)
    share_multiplier #(.N(N), .SW(SW)) u_dom1 (
        .a  (a),
        .ws (w1_reg),
        .p  (p1)
    );
endmodule