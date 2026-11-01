//Design of the activation unit
//4 types of activation functions have been implemented, configured via "mode"

module activation_unit #(
    parameter N = 8
)(
    input wire                clk,
    input wire                reset_n,
    input wire        [1:0]   mode,
    input wire                valid_in,
    input wire signed [N-1:0] x_in,
    input wire signed [N-1:0] clamp_high,
    input wire        [2:0]   leaky_shift,
    output reg                valid_out,
    output reg signed [N-1:0] y_out
);
    localparam [1:0] MODE_PASS = 2'd0, MODE_RELU = 2'd1, MODE_RELU_CLIP = 2'd2, MODE_LEAKY_RELU = 2'd3;
    reg signed [N-1:0] y_comb;

    always @(*) begin
        case(mode)
            MODE_PASS      :  y_comb = x_in;
            MODE_RELU      :  y_comb = (x_in[N-1]) ? {N{1'b0}} : x_in;
            MODE_RELU_CLIP :  y_comb = (x_in[N-1]) ? {N{1'b0}} : ((x_in > clamp_high) ? clamp_high : x_in);
            MODE_LEAKY_RELU:  y_comb = (x_in[N-1]) ? (x_in >>> leaky_shift) : x_in; 
            default        :  y_comb = x_in;
        endcase
    end

    always @(posedge clk) begin
        if(!reset_n) begin
            valid_out <= 1'b0;
            y_out     <= {N{1'b0}};
        end
        else begin
            valid_out <= valid_in;
            y_out     <= y_comb;
        end
    end

endmodule
