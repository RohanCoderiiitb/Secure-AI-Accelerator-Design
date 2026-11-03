//Stand-alone MAC unit: This module performs multiply accumulate (MAC) operations
//Could be useful for MLP workloads
module mac_unit #(
    parameter N = 8,
    parameter ACCW = 32
) (
    input wire clk,
    input wire reset_n,
    input wire en,
    input wire clr,
    input wire signed [N-1:0] act,
    input wire signed [N-1:0] wt,
    output reg [ACCW-1:0] accum
);
    //Multiplication of weight and activation
    wire [2*N-1:0] raw_prod;
    baugh_wooley_multiplier #(
        .N(N)
    ) u_mul(
        .x(act),
        .y(wt),
        .p(raw_prod)
    );
    wire [2*N-1:0] prod = $signed(raw_prod);
    wire signed [ACCW-1:0] prod_ext = {{(ACCW-2*N){prod[2*N-1]}},prod};

    //Accumulation logic
    always @(posedge clk) begin
        if(!reset_n) accum <= {ACCW{1'b0}};
        else if(clr) accum <= (en) ? prod_ext : {ACCW{1'b0}};
        else if(en)  accum <= accum + prod_ext;
    end

endmodule

//Processing element for systolic array integration
//Followed a weight stationary dataflow
//Weights statically loaded and stored in a register, activations propagating horizontally and spatial sums propagating vertically
module processing_element #(
    parameter N = 8,
    parameter ACCW = 32
) (
    input wire clk,
    input wire reset_n,
    input wire wt_load,
    input wire signed [N-1:0] wt_in,
    input wire valid_in,
    input wire signed [N-1:0] act_in,               // Received from the west
    input wire signed [ACCW-1:0] psum_in,           // Received from the north
    output reg valid_out,
    output wire signed [N-1:0] wt_out,                   
    output reg signed [N-1:0] act_out,              // Propagated eastwards
    output reg signed [ACCW-1:0] psum_out           // Propagated southwards
);
    reg signed [N-1:0] wt_reg;                      // wt_in is latched into this register inside the PE node          
    assign wt_out = wt_reg;
    
    wire [2*N-1:0] raw_prod;
    baugh_wooley_multiplier #(
        .N(N)
    ) u_mul(
        .x(act_in),
        .y(wt_reg),
        .p(raw_prod)
    );

    //Sign extending the product
    wire signed [ACCW-1:0] prod = {{(ACCW-2*N){raw_prod[2*N-1]}}, raw_prod};

    //Spatial accumulation, and propagation of the outputs to the neighbouring processing elements in the systolic array
    always @(posedge clk) begin
        if(!reset_n) begin
            valid_out <= 1'b0;
            act_out <= {N{1'b0}};
            wt_reg <= {N{1'b0}};
            psum_out <= {ACCW{1'b0}};
        end else begin
            if(wt_load) wt_reg <= wt_in;
            act_out <= act_in;
            psum_out <= psum_in + prod;
            valid_out <= valid_in;
        end
    end

endmodule 