// TFLite requantizer: wide accumulator -> INT8

module requantize #(
    parameter N    = 8,
    parameter ACCW = 19,
    parameter MW   = 16,
    parameter SW   = 6,
    parameter BMW  = 48                  // width of bm_in = bias*m0
)(
    input wire                   clk,
    input wire                   reset_n,
    input wire                   valid_in,
    input wire signed [ACCW-1:0] acc_in,
    input wire signed [BMW-1:0]  bm_in,
    input wire signed [MW-1:0]   m0_in,
    input wire        [SW-1:0]   shift_in,
    output reg                   valid_out,
    output reg        [N-1:0]    q_out,
    output reg                   sat_out
);

    localparam PW   = ((ACCW + MW > BMW) ? ACCW + MW : BMW) + 1;
    localparam LH   = MW / 2;            // m0 is split into a high and a low half
    localparam signed [N-1:0]  Q_HI   =  (1 <<< (N-1)) - 1;
    localparam signed [N-1:0]  Q_LO   = -(1 <<< (N-1));
    localparam signed [PW-1:0] LIM_HI =  (1 <<< (N-1)) - 1;
    localparam signed [PW-1:0] LIM_LO = -(1 <<< (N-1));
    localparam        [PW-1:0] ONE    = {{(PW-1){1'b0}}, 1'b1};

    // 5-stage pipeline, one result per cycle

    // Per-layer constant bias*m0 + round, registered (static within a layer)
    wire signed [PW-1:0] round_add = (shift_in == 0) ? {PW{1'b0}} : (ONE <<< (shift_in - 1));
    reg  signed [PW-1:0] ra;             // round_add, registered before the add
    reg  signed [PW-1:0] kr;

    // Stage 1
    wire signed [ACCW+LH:0]      pl = acc_in * $signed({1'b0, m0_in[LH-1:0]});
    wire signed [ACCW+MW-LH-1:0] ph = acc_in * $signed(m0_in[MW-1:LH]);
    reg v1;
    reg signed [ACCW+LH:0]      pl_s1;
    reg signed [ACCW+MW-LH-1:0] ph_s1;

    // Stage 2: product halves; stage 3: + bias*m0 + round
    reg v2, v3;
    reg signed [PW-1:0] p_s2, sum_s3;

    // Stage 4: shift; stage 5: clamp
    reg v4;
    reg signed [PW-1:0] scaled;
    wire                 over_hi = (scaled > LIM_HI);
    wire                 over_lo = (scaled < LIM_LO);

    always @(posedge clk) begin
        ra <= round_add;
        kr <= bm_in + ra;
        if(!reset_n) begin
            v1        <= 1'b0;
            pl_s1     <= {(ACCW+LH+1){1'b0}};
            ph_s1     <= {(ACCW+MW-LH){1'b0}};
            v2        <= 1'b0;
            v3        <= 1'b0;
            v4        <= 1'b0;
            p_s2      <= {PW{1'b0}};
            sum_s3    <= {PW{1'b0}};
            scaled    <= {PW{1'b0}};
            q_out     <= {N{1'b0}};
            sat_out   <= 1'b0;
            valid_out <= 1'b0;
        end
        else begin
            // Stage 1
            v1     <= valid_in;
            pl_s1  <= pl;
            ph_s1  <= ph;
            // Stage 2
            v2     <= v1;
            p_s2   <= pl_s1 + (ph_s1 <<< LH);
            // Stage 3
            v3     <= v2;
            sum_s3 <= p_s2 + kr;
            // Stage 4
            v4     <= v3;
            scaled <= sum_s3 >>> shift_in;
            // Stage 5
            valid_out <= v4;
            sat_out   <= over_hi | over_lo;
            q_out     <= (over_hi) ? Q_HI : ((over_lo) ? Q_LO : scaled[N-1:0]);
        end
    end

endmodule
