`timescale 1ns/1ps
//=====================================================================
// tb_qif_gbuf.sv -- EXHAUSTIVE QIF capture for global_buffer.
//
// Threat model: the SRAM output register transitions from the previous
// rd_data to the new word, creating HD-proportional switching.
//
// Enumeration space:
//   secret  = the byte written to one address              256 values
//   context = read address (= written address)          GB_DEPTH values
//   Total:  256 * GB_DEPTH traces (default 256*64 = 16,384, fast)
//
// Protocol per trace:
//   1. Wash read of `context' (uncaptured) -- loads rd_data with the
//      FIXED background value so the transition below is always
//      background -> secret, never (previous trace's secret) -> secret.
//   2. Write the secret byte to address `context'.
//   3. Perform one read of address `context'.  Capture window = 1 cycle
//      (the posedge that latches rd_data).
//   4. Restore background at `context' for the next trace's wash read.
//
// Other addresses hold a fixed background pattern so the SRAM is in a
// realistic state rather than all-zero.
//
// Compile-time knobs:
//   GB_WORD_WIDTH  default 8
//   GB_DEPTH       default 64
//=====================================================================
module tb_qif_gbuf;

    parameter GB_WORD_WIDTH = 8;
    parameter GB_DEPTH      = 64;
    parameter GB_ADDR_WIDTH = (GB_DEPTH <= 1) ? 1 : $clog2(GB_DEPTH);

    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 2;   // rd_en posedge + latch posedge

    reg                       clk = 1'b0;
    reg                       wr_en, rd_en;
    reg  [GB_ADDR_WIDTH-1:0]  wr_addr, rd_addr;
    reg  [GB_WORD_WIDTH-1:0]  wr_data;
    wire [GB_WORD_WIDTH-1:0]  rd_data;

    (* dont_touch = "yes" *)
    global_buffer #(
        .GB_WORD_WIDTH (GB_WORD_WIDTH),
        .GB_DEPTH      (GB_DEPTH),
        .GB_ADDR_WIDTH (GB_ADDR_WIDTH)
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

    // Fixed background that all other addresses hold throughout the run.
    reg [GB_WORD_WIDTH-1:0] bg [0:GB_DEPTH-1];

    integer si, ki, i;
    reg [GB_WORD_WIDTH-1:0] sv;

    initial begin
        qif_get_config("qif_gbuf", GB_DEPTH);
        qif_total = 256 * GB_DEPTH;

        // Seed the background pattern (written once before the sweep)
        for (i = 0; i < GB_DEPTH; i = i + 1)
            bg[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        for (i = 0; i < GB_DEPTH && i < 128; i = i + 1)
            $dumpvars(1, u_dut.u_mem.mem[i]);

        qif_open_meta("global_buffer", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] gbuf exhaustive: 256 secrets x %0d contexts = %0d traces",
                 GB_DEPTH, qif_total);

        // One-time initialisation
        wr_en = 1'b0; rd_en = 1'b0;
        wr_addr = {GB_ADDR_WIDTH{1'b0}}; rd_addr = {GB_ADDR_WIDTH{1'b0}};
        wr_data = {GB_WORD_WIDTH{1'b0}};
        repeat (4) @(posedge clk);

        // Write background pattern to every address
        for (i = 0; i < GB_DEPTH; i = i + 1) begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = i[GB_ADDR_WIDTH-1:0];
            wr_data = bg[i];
            @(posedge clk);
        end
        @(negedge clk); wr_en = 1'b0;
        repeat (4) @(posedge clk);

        // Enumeration: ki = context (= read address), si = secret byte
        for (ki = 0; ki < GB_DEPTH; ki = ki + 1) begin
            for (si = 0; si < 256; si = si + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[GB_WORD_WIDTH-1:0];

                    // Wash read: load rd_data with the FIXED background
                    // value before the secret is written, so every trace's
                    // captured transition is background -> secret, never
                    // (previous trace's secret) -> secret. Uncaptured: no
                    // trace_t0 is set here.
                    @(negedge clk);
                    rd_en   = 1'b1;
                    rd_addr = ki[GB_ADDR_WIDTH-1:0];
                    @(posedge clk);
                    @(negedge clk); rd_en = 1'b0;

                    // Write the secret byte to the target address (untriggered)
                    wr_en   = 1'b1;
                    wr_addr = ki[GB_ADDR_WIDTH-1:0];
                    wr_data = sv;
                    @(posedge clk);
                    @(negedge clk); wr_en = 1'b0;

                    // Capture: one read cycle
                    rd_en   = 1'b1;
                    rd_addr = ki[GB_ADDR_WIDTH-1:0];
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk); rd_en = 1'b0;
                    @(posedge clk);   // rd_data now stable
                    qif_trace_end(si, $signed(sv), ki, ki);
                    qif_progress(qif_idx, qif_total);

                    // Restore background so the next trace sees a clean SRAM
                    @(negedge clk);
                    wr_en   = 1'b1;
                    wr_addr = ki[GB_ADDR_WIDTH-1:0];
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