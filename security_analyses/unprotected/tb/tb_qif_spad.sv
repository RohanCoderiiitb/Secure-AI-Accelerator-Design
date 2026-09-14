`timescale 1ns/1ps
//=====================================================================
// tb_qif_spad.sv -- EXHAUSTIVE QIF capture for the activation scratchpad.
//
// The activation scratchpad is an 8-bit x SPAD_DEPTH SRAM.  In the
// top-level one scratchpad per row holds WAVES activation values.
// The leakage surface is identical to global_buffer: the rd_data
// output register transitions on every read.
//
// Enumeration space:
//   secret  = activation byte written to one location    256 values
//   context = scratchpad address (wave index)        SPAD_DEPTH values
//   Total:  256 * SPAD_DEPTH traces (default 256*4 = 1024, very fast)
//
// Protocol per trace: identical to tb_qif_gbuf.sv, with scratchpad
// substituted for global_buffer.
//
// Compile-time knobs:
//   DATA_WIDTH  default 8
//   SPAD_DEPTH  default 4   (= WAVES in the top-level)
//=====================================================================
module tb_qif_spad;

    parameter DATA_WIDTH = 8;
    parameter SPAD_DEPTH = 4;
    parameter ADDR_WIDTH = (SPAD_DEPTH <= 1) ? 1 : $clog2(SPAD_DEPTH);

    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 2;

    reg                      clk = 1'b0;
    reg                      wr_en, rd_en;
    reg  [ADDR_WIDTH-1:0]    wr_addr, rd_addr;
    reg  [DATA_WIDTH-1:0]    wr_data;
    wire [DATA_WIDTH-1:0]    rd_data;

    (* dont_touch = "yes" *)
    scratchpad #(
        .DATA_WIDTH (DATA_WIDTH),
        .SPAD_DEPTH (SPAD_DEPTH),
        .ADDR_WIDTH (ADDR_WIDTH)
    ) u_dut (
        .clk     (clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    reg [DATA_WIDTH-1:0] bg [0:SPAD_DEPTH-1];

    integer si, ki, i;
    reg [DATA_WIDTH-1:0] sv;

    initial begin
        qif_get_config("qif_spad", SPAD_DEPTH);
        qif_total = 256 * SPAD_DEPTH;

        for (i = 0; i < SPAD_DEPTH; i = i + 1)
            bg[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        for (i = 0; i < SPAD_DEPTH; i = i + 1)
            $dumpvars(1, u_dut.u_mem.mem[i]);

        qif_open_meta("scratchpad", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] spad exhaustive: 256 secrets x %0d contexts = %0d traces",
                 SPAD_DEPTH, qif_total);

        wr_en = 1'b0; rd_en = 1'b0;
        wr_addr = {ADDR_WIDTH{1'b0}}; rd_addr = {ADDR_WIDTH{1'b0}};
        wr_data = {DATA_WIDTH{1'b0}};
        repeat (4) @(posedge clk);

        // Write background to all locations
        for (i = 0; i < SPAD_DEPTH; i = i + 1) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = i[ADDR_WIDTH-1:0];
            wr_data = bg[i];
            @(posedge clk);
        end
        @(negedge clk); wr_en = 1'b0;
        repeat (4) @(posedge clk);

        for (ki = 0; ki < SPAD_DEPTH; ki = ki + 1) begin
            for (si = 0; si < 256; si = si + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[DATA_WIDTH-1:0];

                    // Write secret to target address (untriggered)
                    @(negedge clk);
                    wr_en   = 1'b1;
                    wr_addr = ki[ADDR_WIDTH-1:0];
                    wr_data = sv;
                    @(posedge clk);
                    @(negedge clk); wr_en = 1'b0;

                    // Capture: one read cycle
                    rd_en   = 1'b1;
                    rd_addr = ki[ADDR_WIDTH-1:0];
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); rd_en = 1'b0;
                    @(posedge clk);
                    qif_trace_end(si, $signed(sv), ki, ki);
                    qif_progress(qif_idx, qif_total);

                    // Restore background
                    @(negedge clk);
                    wr_en   = 1'b1;
                    wr_addr = ki[ADDR_WIDTH-1:0];
                    wr_data = bg[ki];
                    @(posedge clk);
                    @(negedge clk); wr_en = 1'b0;
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
