module global_buffer #(
    parameter GB_WORD_WIDTH = 32,
    parameter GB_DEPTH      = 512,
    parameter GB_ADDR_WIDTH = (GB_DEPTH <= 1) ? 1 : $clog2(GB_DEPTH)
) (
    input  wire                        clk,

    input  wire                        wr_en,
    input  wire [GB_ADDR_WIDTH-1:0]    wr_addr,
    input  wire [GB_WORD_WIDTH-1:0]    wr_data,

    input  wire                        rd_en,
    input  wire [GB_ADDR_WIDTH-1:0]    rd_addr,
    output wire [GB_WORD_WIDTH-1:0]    rd_data
);
    sram_2p #(
        .DATA_WIDTH (GB_WORD_WIDTH),
        .DEPTH      (GB_DEPTH),
        .ADDR_WIDTH (GB_ADDR_WIDTH)
    ) u_mem (
        .clk     (clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );
endmodule
