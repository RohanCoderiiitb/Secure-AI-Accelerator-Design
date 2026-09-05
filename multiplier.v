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

// This module generates the partial products generated during the multiplication phase
// Since it is a signed multiplication, multiplying a regular bit with a signed bit gives a negative mixed term
// Instead of subtracting them, the BW algorithm flips the bits, adds it, and then adds 1 to compensate for the addition of the flipped term
module partial_product_generator #(
    parameter N = 8
)(
    input  [N-1:0]   x,
    input  [N-1:0]   y,
    output [N*N-1:0] pp_flat
);
    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin: g_row
            for (j = 0; j < N; j = j + 1) begin: g_col
                if (i==N-1 && j==N-1)
                    assign pp_flat[i*N + j] = (x[i] & y[j]);
                else if (i==N-1 || j==N-1)
                    assign pp_flat[i*N + j] = ~(x[i] & y[j]);
                else
                    assign pp_flat[i*N + j] = (x[i] & y[j]);
            end
        end
    endgenerate
endmodule

// This module sums the generated partial products using a regular Carry-Save Adder (CSA) array
// It avoids slow horizontal carry delays by passing carries diagonally down to the next row
// The two "+1" compensation constants required by the BW algorithm are injected into the final vector merge adder's carry-in and the Most Significant Bit
module baugh_wooley_multiplier #(
    parameter N = 8
) (
    input  wire [N-1:0]   x,
    input  wire [N-1:0]   y,
    output wire [2*N-1:0] p
);
    wire [N*N-1:0] pp_flat;
    wire [N-1:0]   pp [0:N-1];

    partial_product_generator #(.N(N)
    ) u_ppgen (.x(x),
               .y(y),
               .pp_flat(pp_flat)
    );

    genvar gi, gj;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : g_unflat
            for (gj = 0; gj < N; gj = gj + 1) begin : g_unflat_j
                assign pp[gi][gj] = pp_flat[gi*N+gj];
            end
        end
    endgenerate

    wire [N-1:0] s [0:N-1];
    wire [N-1:0] c [0:N-1];

    assign s[0] = pp[0];
    assign c[0] = {N{1'b0}};

    genvar i, j;
    generate
        for (i = 1; i < N; i = i + 1) begin : g_arr_row
            for (j = 0; j < N; j = j + 1) begin : g_arr_col
                if (j < N-1) begin : g_fa
                    full_adder u_fa (
                        .a   (pp[i][j]),
                        .b   (s[i-1][j+1]),
                        .cin (c[i-1][j]),
                        .s   (s[i][j]),
                        .cout(c[i][j])
                    );
                end else begin : g_ha
                    half_adder u_ha (
                        .a   (pp[i][N-1]),
                        .b   (c[i-1][N-1]),
                        .s   (s[i][N-1]),
                        .cout(c[i][N-1])
                    );
                end
            end
        end
    endgenerate

    generate
        for (i = 0; i < N; i = i + 1) begin : g_plow
            assign p[i] = s[i][0];
        end
    endgenerate

    wire [N-2:0] vma_a = s[N-1][N-1:1];
    wire [N-2:0] vma_b = c[N-1][N-2:0];
    wire [N-1:0] vma_c;
    wire [N-2:0] vma_s;

    assign vma_c[0] = 1'b1;

    generate
        for (i = 0; i < N-1; i = i + 1) begin : g_vma
            full_adder u_vma (
                .a   (vma_a[i]),
                .b   (vma_b[i]),
                .cin (vma_c[i]),
                .s   (vma_s[i]),
                .cout(vma_c[i+1])
            );
        end
    endgenerate

    assign p[2*N-2:N] = vma_s;

    assign p[2*N-1] = vma_c[N-1] ^ c[N-1][N-1] ^ 1'b1;

endmodule