//Parameterized Systolic Array Design
//Input skew and Output de-skew left out of the design.
//This has been done to prevent their switching activity resulting
//from shift chains from contaminating the analysis of the systolic
//array's switching activity and power consumption.

module systolic_array #(
    parameter N     = 8,
    parameter ACCW  = 32,
    parameter ROWS  = 16,
    parameter COLS  = 16
) (
    input wire                  clk, 
    input wire                  reset_n,
    input wire                  wt_load,           //Enable signal to populate array with weights
    input wire [COLS*N-1:0]     wt_flat,           //Weights entering array from north
    input wire [ROWS-1:0]       valid_act_in,
    input wire [ROWS*N-1:0]     act_flat,          //Activations entering array from the west
    input wire [COLS*ACCW-1:0]  psum_flat,         //Injecting partial sums from north, tied to 0 for a tile
    output wire [COLS*ACCW-1:0] psum_out,          //Psum propagating out of the array from south
    output wire [COLS-1:0]      valid_sum_out,
    output wire [ROWS*N-1:0]    act_out,           //Pass through activations
    output wire [ROWS-1:0]      valid_act_out
);

    //Unpacking the flat input ports to form internal 2D arrays
    //+1 padding allowed for the boundary entries or outputs
    wire signed [N-1:0]    act  [0:ROWS-1][0:COLS];
    wire                   vld  [0:ROWS-1][0:COLS];
    wire signed [ACCW-1:0] psum [0:ROWS][0:COLS-1];
    wire signed [N-1:0]    wt   [0:ROWS][0:COLS-1];

    genvar r, c;

    //Boundary conditions for the grid
    generate
        for(r=0; r<ROWS; r=r+1) begin : g_west
            assign act[r][0]             = act_flat[r*N+:N];
            assign vld[r][0]             = valid_act_in[r];
            assign act_out[r*N+:N]       = act[r][COLS];
            assign valid_act_out[r] = act[r][COLS];
        end
        for(c=0; c<COLS; c=c+1) begin : g_north
            assign wt[0][c]               = wt_flat[c*N+:N];
            assign psum[0][c]             = psum_flat[c*ACCW+:ACCW];
            assign psum_out[c*ACCW+:ACCW] = psum[ROWS][c];   
        end
    endgenerate

    //Grid of processing elements
    generate
        for(r=0; r<ROWS; r=r+1) begin : g_row
            for(c=0; c<COLS; c=c+1) begin: g_col
                wire                   pe_valid_out;
                wire signed [N-1:0]    pe_wt_out;
                wire signed [N-1:0]    pe_act_out;
                wire signed [ACCW-1:0] pe_psum_out;

                (* dont_touch = "yes" *)
                processing_element #(
                    .N    (N),
                    .ACCW (ACCW)
                ) pe_inst(
                    .clk(clk),
                    .reset_n   (reset_n),
                    .wt_load   (wt_load),
                    .wt_in     (wt[r][c]),
                    .valid_in  (vld[r][c]),
                    .act_in    (act[r][c]),
                    .psum_in   (psum[r][c]),
                    .valid_out (pe_valid_out),
                    .wt_out    (pe_wt_out),
                    .act_out   (pe_act_out),
                    .psum_out  (pe_psum_out)
                );

                assign act  [r][c+1] = pe_act_out;
                assign vld  [r][c+1] = pe_valid_out;
                assign wt   [r+1][c] = pe_wt_out;
                assign psum [r+1][c] = pe_psum_out;
            end
        end
    endgenerate

    //Asserting the valid bits for the psum outputs from the grid
    generate
        for(c=0; c<COLS; c=c+1) begin: g_south_valid
            assign valid_sum_out[c] = vld[ROWS-1][c+1];
        end
    endgenerate
endmodule