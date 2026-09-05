//Requantization block design
//Essential to convert the 32 bit acc to INT8
//Adopts tflite's quantization algorithm to convert to INT8

module requantize #(
    parameter N    = 8,
    parameter ACCW = 32,
    parameter MW   = 32,
    parameter SW   = 6  
)(
    input wire                   clk,
    input wire                   reset_n,
    input wire                   valid_in,
    input wire signed [ACCW-1:0] acc_in,
    input wire signed [ACCW-1:0] bias_in,
    input wire signed [MW-1:0]   m0_in,
    input wire        [SW-1:0]   shift_in,
    output reg                   valid_out,
    output reg        [N-1:0]    q_out,
    output reg                   sat_out
);

    localparam PW   = ACCW + MW;                 
    localparam signed [N-1:0]  Q_HI   =  (1 <<< (N-1)) - 1;
    localparam signed [N-1:0]  Q_LO   = -(1 <<< (N-1));
    localparam signed [PW-1:0] LIM_HI =  (1 <<< (N-1)) - 1;
    localparam signed [PW-1:0] LIM_LO = -(1 <<< (N-1));
    localparam        [PW-1:0] ONE    = {{(PW-1){1'b0}}, 1'b1};

    //Divided in 3 stages
    //Stage 0: addition with the bias
    //Stage 1: multiplication with m0 to scale up
    //Stage 2: rounding off, shifting, and final bounds check, clamping accordingly

    //Pipeline register for stage 1
    reg v1;
    reg signed [ACCW-1:0] biased_s1;
    reg signed [MW-1:0]   m0_s1;
    reg        [SW-1:0]   sh_s1;

    //Pipeline register for stage 2
    reg v2;
    reg signed [PW-1:0] prod_s2;
    reg        [SW-1:0] sh_s2;

    //Stage 3 Implementation
    wire signed [PW-1:0] round_add = (sh_s2 == 0) ? {PW{1'b0}} : (ONE <<< (sh_s2 - 1));
    wire signed [PW-1:0] scaled    = (prod_s2 + round_add) >>> sh_s2;
    wire                 over_hi   = (scaled > LIM_HI);
    wire                 over_lo   = (scaled < LIM_LO);

    always @(posedge clk) begin
        if(!reset_n) begin
            v1        <= 1'b0; 
            biased_s1 <= {ACCW{1'b0}};
            m0_s1     <= {MW{1'b0}};
            sh_s1     <= {SW{1'b0}};
            v2        <= 1'b0; 
            prod_s2   <= {PW{1'b0}};
            sh_s2     <= {SW{1'b0}};
            q_out     <= {N{1'b0}};
            sat_out   <= 1'b0;
            valid_out <= 1'b0;
        end
        else begin
            //Stage 1
            v1        <= valid_in;
            biased_s1 <= acc_in + bias_in;
            m0_s1     <= m0_in;
            sh_s1     <= shift_in;
            //Stage 2
            v2      <= v1;
            prod_s2 <= biased_s1 * m0_s1;
            sh_s2   <= sh_s1;
            //Stage 3
            valid_out <= v2;
            sat_out   <= over_hi | over_lo;
            q_out     <= (over_hi) ? Q_HI : ((over_lo) ? Q_LO : scaled[N-1:0]);
        end
    end

endmodule