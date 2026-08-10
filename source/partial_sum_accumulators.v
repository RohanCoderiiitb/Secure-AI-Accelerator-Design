//Partial sum accumulator design
//Integrated at the southern end of the systolic array to accumulate all of the partial sums
//Since, the grid can't process the entire matrix of inputs, it's sent in as tiles of smaller sizes
//So, the module accumulates these partial sums at the end of the array

module psum_accum #(
    parameter N     = 8,
    parameter ACCW  = 32,
    parameter COLS  = 5,
    parameter DEPTH = 32,
    parameter AW    = 6
)(
    input wire                  clk,
    input wire                  reset_n,
    input wire                  tile_start,       //1 cycle Pulse indicating a new tile to reset counters
    input wire                  first_tile,       //Pulse indicating the influx of the first tile
    input wire                  last_tile,        //Pulse indicating the influx of the last tile

    //Flattened inputs (valid, and partial sums) and outputs (valid, and accumulated sums)
    input wire [COLS-1:0]       valid_in,         
    input wire [COLS*ACCW-1:0]  psum_in,
    output wire [COLS*ACCW-1:0] psum_out,
    output wire [COLS-1:0]      valid_out,

    output wire [COLS-1:0]      ovf               //Overflow flag if the address counter exceeds the DEPTH
);
    genvar c;
    generate
        for(c=0; c<COLS; c=c+1) begin: g_lane

            reg signed [ACCW-1:0] mem [0:DEPTH-1];
            reg [AW-1:0]   addr;
            reg signed [ACCW-1:0] acc_r;
            reg            vld_r;
            reg            ovf_r;

            wire signed [ACCW-1:0] din  = psum_in[c*ACCW+:ACCW];
            wire signed [ACCW-1:0] prev = (first_tile) ? {ACCW{1'b0}} : mem[addr];
            wire signed [ACCW-1:0] sum  = din + prev;

            always @(posedge clk) begin
                if(!reset_n) begin
                    addr  <= {AW{1'b0}};
                    acc_r <= {ACCW{1'b0}};
                    vld_r <= 1'b0;
                    ovf_r <= 1'b0;
                end
                else begin
                    if(tile_start) begin
                        addr  <= {AW{1'b0}};
                        ovf_r <= 1'b0;
                    end
                    vld_r <= valid_in[c] & last_tile;
                    if(valid_in[c]) begin
                        mem[addr] <= sum;
                        acc_r      <= sum;
                        if(addr > DEPTH) ovf_r <= 1'b1;
                        else if(!tile_start) addr <= addr + 1;
                    end
                end
            end
            assign psum_out  [c*ACCW+:ACCW] = acc_r;
            assign valid_out [c]            = vld_r;
            assign ovf       [c]            = ovf_r;
        end
    endgenerate

endmodule