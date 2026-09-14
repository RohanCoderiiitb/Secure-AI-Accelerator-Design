// Scratchpad: one localized SRAM sitting between the Global Buffer and the systolic array's operand ports.

module scratchpad #(
    parameter DATA_WIDTH = 8,
    parameter SPAD_DEPTH = 64,
    parameter ADDR_WIDTH = (SPAD_DEPTH <= 1) ? 1 : $clog2(SPAD_DEPTH)
) (
    input  wire                     clk,

    input  wire                     wr_en,
    input  wire [ADDR_WIDTH-1:0]    wr_addr,
    input  wire [DATA_WIDTH-1:0]    wr_data,

    input  wire                     rd_en,
    input  wire [ADDR_WIDTH-1:0]    rd_addr,
    output wire [DATA_WIDTH-1:0]    rd_data
);
    sram_2p #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (SPAD_DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
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
