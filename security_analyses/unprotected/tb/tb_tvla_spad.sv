`timescale 1ns/1ps
//=====================================================================
// tb_tvla_spad.sv -- TVLA dataset generation for the activation
//                    scratchpad (sram_2p wrapper, 8-bit x DEPTH).
//
// In the top-level each of the ARRAY_ROWS rows gets its own scratchpad
// of depth WAVES holding one activation vector.  The leakage surface is
// the same as for global_buffer: the rd_data output register transitions
// at every read, with switching proportional to HD(prev_word, new_word).
//
// Because SPAD_DEPTH is small (default 4, matching WAVES=4), one trace
// covers a write of all SPAD_DEPTH words followed by a read of all
// SPAD_DEPTH words.  The capture window covers only the reads.
//
// TVLA_TARGET:
//   "data" (default) -- activation data carries the contrast.
//   "addr"           -- data is fixed, address pattern varies.
//
// Compile-time knobs (override with -P):
//   DATA_WIDTH   default 8
//   SPAD_DEPTH   default 4   (= WAVES in the top-level)
//=====================================================================
module tb_tvla_spad;

    parameter DATA_WIDTH = 8;
    parameter SPAD_DEPTH = 4;
    parameter ADDR_WIDTH = (SPAD_DEPTH <= 1) ? 1 : $clog2(SPAD_DEPTH);

    localparam real CLK_NS = 10.0;
    localparam CAPTURE = SPAD_DEPTH;   // one read per word
    localparam FLUSH   = 4;

    reg                       clk = 1'b0;
    reg                       wr_en, rd_en;
    reg  [ADDR_WIDTH-1:0]     wr_addr, rd_addr;
    reg  [DATA_WIDTH-1:0]     wr_data;
    wire [DATA_WIDTH-1:0]     rd_data;

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

    // Explicitly dump mem[] -- $dumpvars(0,u_dut) does NOT
    // descend into memory arrays under Icarus.
    task dump_all_mem;
        integer i;
        begin
            for (i = 0; i < SPAD_DEPTH; i = i + 1)
                $dumpvars(1, u_dut.u_mem.mem[i]);
        end
    endtask

    reg [DATA_WIDTH-1:0] fix_data [0:SPAD_DEPTH-1];
    reg [DATA_WIDTH-1:0] cur_data [0:SPAD_DEPTH-1];

    integer t, i;
    reg     grp, eff;

    initial begin
        sca_get_config("spad");

        for (i = 0; i < SPAD_DEPTH; i = i + 1)
            fix_data[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        dump_all_mem;

        sca_open_meta("scratchpad", CLK_NS, CAPTURE);
        $display("[SCA] spad DATA_WIDTH=%0d SPAD_DEPTH=%0d capture=%0d cycles",
                 DATA_WIDTH, SPAD_DEPTH, CAPTURE);

        wr_en = 1'b0; rd_en = 1'b0;
        wr_addr = {ADDR_WIDTH{1'b0}}; rd_addr = {ADDR_WIDTH{1'b0}};
        wr_data = {DATA_WIDTH{1'b0}};

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // R5: always draw random values for both groups
            for (i = 0; i < SPAD_DEPTH; i = i + 1)
                cur_data[i] = rand_i8(0);

            if (!eff)
                for (i = 0; i < SPAD_DEPTH; i = i + 1)
                    cur_data[i] = fix_data[i];

            // ---- write phase, untriggered (R4) ----
            @(negedge clk);
            for (i = 0; i < SPAD_DEPTH; i = i + 1) begin
                wr_en   = 1'b1;
                wr_addr = i[ADDR_WIDTH-1:0];
                wr_data = cur_data[i];
                rd_en   = 1'b0;
                @(posedge clk);
                @(negedge clk);
            end
            wr_en   = 1'b0;
            wr_addr = {ADDR_WIDTH{1'b0}};
            wr_data = {DATA_WIDTH{1'b0}};

            // ---- flush, untriggered ----
            rd_en = 1'b0;
            repeat (FLUSH) @(posedge clk);

            // ---- capture window: sequential reads ----
            for (i = 0; i < SPAD_DEPTH; i = i + 1) begin
                @(negedge clk);
                rd_en   = 1'b1;
                rd_addr = i[ADDR_WIDTH-1:0];
                @(posedge clk);
                if (i == 0) sca_trace_begin;
            end

            @(negedge clk);
            rd_en   = 1'b0;
            rd_addr = {ADDR_WIDTH{1'b0}};
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
