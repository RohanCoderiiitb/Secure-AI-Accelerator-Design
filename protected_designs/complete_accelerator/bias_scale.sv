// Per-layer precompute of bias*m0 for every column (shared sequential multiplier)
module bias_scale #(
    parameter COLS = 5,
    parameter BW   = 32,
    parameter MW   = 16,
    parameter BMW  = BW + MW
) (
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 start,
    input  wire [COLS*BW-1:0]   bias_flat,
    input  wire [COLS*MW-1:0]   m0_flat,
    output reg  [COLS*BMW-1:0]  bm_flat,
    output wire                 busy
);
    localparam ND  = (MW + 1) / 2;                       // radix-4 digits
    localparam CIW = (COLS > 1) ? $clog2(COLS) : 1;
    localparam DIW = (ND > 1) ? $clog2(ND) : 1;
    localparam H   = BMW / 2;                            // final add split in two halves
    localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_DIG = 3'd2, S_SUM = 3'd3, S_SUMH = 3'd4;

    reg [2:0]          st;
    reg [CIW-1:0]      col;
    reg [DIW-1:0]      dig;
    reg [BMW-1:0]      b;          // sign-extended bias of the current column
    reg [2*ND-1:0]     m;          // m0 sign-extended to 2*ND bits, shifted out 2 at a time
    reg [BMW-1:0]      cs, cc;     // carry-save accumulator
    reg [H-1:0]        lo;         // low half of the final sum
    reg                cy;         // carry out of the low half

    assign busy = (st != S_IDLE);

    // one radix-4 Horner step
    wire [BMW-1:0] t1  = m[2*ND-1] ? (b << 1) : {BMW{1'b0}};
    wire [BMW-1:0] t2  = m[2*ND-2] ? b        : {BMW{1'b0}};
    wire [BMW-1:0] u0  = cs << 2;
    wire [BMW-1:0] u1  = cc << 2;
    wire [BMW-1:0] s1  = u0 ^ u1 ^ t1;                   // 3:2
    wire [BMW-1:0] c1  = ((u0 & u1) | (u0 & t1) | (u1 & t1)) << 1;
    wire [BMW-1:0] s2  = s1 ^ c1 ^ t2;                   // 3:2
    wire [BMW-1:0] c2  = ((s1 & c1) | (s1 & t2) | (c1 & t2)) << 1;

    wire [BW-1:0]  bias_c = bias_flat[col*BW +: BW];
    wire [MW-1:0]  m0_c   = m0_flat[col*MW +: MW];

    always @(posedge clk) begin
        if (!reset_n) begin
            st      <= S_IDLE;
            col     <= {CIW{1'b0}};
            dig     <= {DIW{1'b0}};
            bm_flat <= {(COLS*BMW){1'b0}};
        end else begin
            case (st)
                S_IDLE: if (start) begin
                    col <= {CIW{1'b0}};
                    st  <= S_LOAD;
                end
                S_LOAD: begin
                    b   <= {{(BMW-BW){bias_c[BW-1]}}, bias_c};
                    m   <= {{(2*ND-MW){m0_c[MW-1]}}, m0_c};
                    // signed m0: start at -bias, which the ND steps scale by 4^ND = 2^(2*ND)
                    cs  <= m0_c[MW-1] ? ~{{(BMW-BW){bias_c[BW-1]}}, bias_c} : {BMW{1'b0}};
                    cc  <= {{(BMW-1){1'b0}}, m0_c[MW-1]};
                    dig <= {DIW{1'b0}};
                    st  <= S_DIG;
                end
                S_DIG: begin
                    cs  <= s2;
                    cc  <= c2;
                    m   <= m << 2;
                    dig <= dig + 1'b1;
                    if (dig == ND - 1) st <= S_SUM;
                end
                S_SUM: begin
                    {cy, lo} <= {1'b0, cs[H-1:0]} + {1'b0, cc[H-1:0]};
                    st       <= S_SUMH;
                end
                S_SUMH: begin
                    bm_flat[col*BMW +: BMW] <= {cs[BMW-1:H] + cc[BMW-1:H] + cy, lo};
                    if (col == COLS - 1) st <= S_IDLE;
                    else begin
                        col <= col + 1'b1;
                        st  <= S_LOAD;
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
