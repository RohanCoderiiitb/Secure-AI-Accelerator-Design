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

// Baugh-Wooley partial-product generator
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

// Carry-save adder array summing the partial products
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

// Two-stage pipelined baugh_wooley_multiplier (registered after CSA row SPLIT and at the output)
module bw_multiplier_pipe #(
    parameter N     = 8,
    parameter SPLIT = 5
) (
    input  wire             clk,
    input  wire [N-1:0]     x,
    input  wire [N-1:0]     y,
    output reg  [2*N-1:0]   p
);
    reg  [N-1:0]     x_q;              // x bits of the stage-2 rows
    reg  [N-1:0]     s_q, c_q;         // CSA row SPLIT, carry-save
    reg  [SPLIT-1:0] pl_q;             // product bits finished in stage 1

    wire [N-1:0] xs;                   // x bit each row sees
    wire [N-1:0] s [0:N-1];
    wire [N-1:0] c [0:N-1];
    wire [N-1:0] pp [0:N-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_x
            assign xs[i] = (i <= SPLIT) ? x[i] : x_q[i];
        end
        for (i = 0; i < N; i = i + 1) begin : g_pp
            for (j = 0; j < N; j = j + 1) begin : g_ppj
                if (i == N-1 && j == N-1)
                    assign pp[i][j] = xs[i] & y[j];
                else if (i == N-1 || j == N-1)
                    assign pp[i][j] = ~(xs[i] & y[j]);
                else
                    assign pp[i][j] = xs[i] & y[j];
            end
        end
    endgenerate

    assign s[0] = pp[0];
    assign c[0] = {N{1'b0}};

    generate
        for (i = 1; i < N; i = i + 1) begin : g_arr_row
            // row SPLIT+1 starts from the registered row SPLIT
            wire [N-1:0] sp = (i == SPLIT + 1) ? s_q : s[i-1];
            wire [N-1:0] cp = (i == SPLIT + 1) ? c_q : c[i-1];
            for (j = 0; j < N; j = j + 1) begin : g_arr_col
                if (j < N-1) begin : g_fa
                    full_adder u_fa (.a(pp[i][j]), .b(sp[j+1]), .cin(cp[j]),
                                     .s(s[i][j]), .cout(c[i][j]));
                end else begin : g_ha
                    half_adder u_ha (.a(pp[i][N-1]), .b(cp[N-1]),
                                     .s(s[i][N-1]), .cout(c[i][N-1]));
                end
            end
        end
    endgenerate

    wire [SPLIT-1:0] pl;
    generate
        for (i = 0; i < SPLIT; i = i + 1) begin : g_pl
            assign pl[i] = s[i][0];
        end
    endgenerate

    // vector merge
    wire [N-1:0] vma = {1'b0, s[N-1][N-1:1]} + {1'b0, c[N-1][N-2:0]} + {{(N-1){1'b0}}, 1'b1};
    wire [N-1:0] plow;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_plow
            if (i < SPLIT)       assign plow[i] = pl_q[i];
            else if (i == SPLIT) assign plow[i] = s_q[0];
            else                 assign plow[i] = s[i][0];
        end
    endgenerate

    always @(posedge clk) begin
        x_q  <= x;
        s_q  <= s[SPLIT];
        c_q  <= c[SPLIT];
        pl_q <= pl;
        p    <= {vma[N-1] ^ c[N-1][N-1] ^ 1'b1, vma[N-2:0], plow};
    end
endmodule
