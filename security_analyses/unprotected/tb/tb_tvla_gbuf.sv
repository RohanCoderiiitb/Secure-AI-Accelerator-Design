`timescale 1ns/1ps
//=====================================================================
// tb_tvla_gbuf.sv -- TVLA dataset generation for the global_buffer
//                    (sram_2p wrapper).
//
// Leakage surface:
//   The dominant side-channel in an SRAM is the Hamming-Weight /
//   Hamming-Distance of rd_data at each read cycle: the output
//   register pre-charges to a value and then transitions to the new
//   word, so switching activity is proportional to HD(old, new).
//   The write-data bus and the address decoder also toggle, but with
//   INT8 inputs the read path dominates.
//
// Protocol:
//   Setup (untriggered, R4):
//     Write DEPTH words. Fixed group: all words = FIXED_BYTE.
//                        Random group: all words = rand_i8() per word.
//   Capture window:
//     Read all DEPTH words sequentially. The window covers DEPTH
//     read cycles; each posedge latches a new rd_data value.
//
// TVLA_TARGET:
//   "data"  (default) -- rd_data carries the contrast.
//   "addr"            -- data is fixed, read-address pattern varies
//                        (only 1-bit increments so this is weak).
//
// Parameters to vary at compile time:
//   GB_WORD_WIDTH  (default 8,  matching the activation scratchpad)
//   GB_DEPTH       (default 64, matching a single activation row)
//=====================================================================
module tb_tvla_gbuf;

    parameter GB_WORD_WIDTH = 8;
    parameter GB_DEPTH      = 64;
    parameter GB_ADDR_WIDTH = (GB_DEPTH <= 1) ? 1 : $clog2(GB_DEPTH);

    localparam real CLK_NS = 10.0;
    localparam CAPTURE = GB_DEPTH;   // one read per word
    localparam FLUSH   = 4;

    reg                          clk = 1'b0;
    reg                          wr_en, rd_en;
    reg  [GB_ADDR_WIDTH-1:0]     wr_addr, rd_addr;
    reg  [GB_WORD_WIDTH-1:0]     wr_data;
    wire [GB_WORD_WIDTH-1:0]     rd_data;

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

    // Explicitly dump mem[] words -- $dumpvars(0,u_dut) does NOT
    // descend into memory arrays under Icarus/VCS.
    integer dump_i;
    task dump_all_mem;
        integer i;
        begin
            for (i = 0; i < GB_DEPTH && i < 128; i = i + 1)
                $dumpvars(1, u_dut.u_mem.mem[i]);
        end
    endtask

    reg [GB_WORD_WIDTH-1:0] fix_data [0:GB_DEPTH-1];
    reg [GB_WORD_WIDTH-1:0] cur_data [0:GB_DEPTH-1];

    integer t, i;
    reg     grp, eff;

    initial begin
        sca_get_config("gbuf");

        for (i = 0; i < GB_DEPTH; i = i + 1)
            fix_data[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        dump_all_mem;

        sca_open_meta("global_buffer", CLK_NS, CAPTURE);
        $display("[SCA] gbuf GB_WORD_WIDTH=%0d GB_DEPTH=%0d capture=%0d cycles",
                 GB_WORD_WIDTH, GB_DEPTH, CAPTURE);

        wr_en = 1'b0; rd_en = 1'b0;
        wr_addr = {GB_ADDR_WIDTH{1'b0}}; rd_addr = {GB_ADDR_WIDTH{1'b0}};
        wr_data = {GB_WORD_WIDTH{1'b0}};

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: draw random data for both groups unconditionally
            for (i = 0; i < GB_DEPTH; i = i + 1)
                cur_data[i] = rand_i8(0);

            // Fixed group uses the fixed constant word vector
            if (!eff)
                for (i = 0; i < GB_DEPTH; i = i + 1)
                    cur_data[i] = fix_data[i];

            // ---- write phase, untriggered (R4) ----
            @(negedge clk);
            for (i = 0; i < GB_DEPTH; i = i + 1) begin
                wr_en   = 1'b1;
                wr_addr = i[GB_ADDR_WIDTH-1:0];
                wr_data = cur_data[i];
                rd_en   = 1'b0;
                @(posedge clk);
                @(negedge clk);
            end
            wr_en   = 1'b0;
            wr_addr = {GB_ADDR_WIDTH{1'b0}};
            wr_data = {GB_WORD_WIDTH{1'b0}};

            // ---- flush, untriggered ----
            rd_en = 1'b0;
            repeat (FLUSH) @(posedge clk);

            // ---- capture window: sequential reads ----
            for (i = 0; i < GB_DEPTH; i = i + 1) begin
                @(negedge clk);
                rd_en   = 1'b1;
                rd_addr = i[GB_ADDR_WIDTH-1:0];
                @(posedge clk);
                if (i == 0) sca_trace_begin;
            end

            @(negedge clk);
            rd_en   = 1'b0;
            rd_addr = {GB_ADDR_WIDTH{1'b0}};
            @(posedge clk);   // drain last rd_data
            sca_trace_end(grp);

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
