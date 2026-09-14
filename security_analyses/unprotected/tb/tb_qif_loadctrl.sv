`timescale 1ns/1ps
//=====================================================================
// tb_qif_loadctrl.sv -- EXHAUSTIVE QIF capture for load_controller.
//
// The load_controller reads every byte of IF_GB and FL_GB, routes them
// through the per-row scratchpads, and assembles wt_flat -- so every
// byte in either memory is a potential secret.
//
// Enumeration space (default):
//   secret  = one activation byte in IF_GB (address 0)    256 values
//   context = IF_GB address carrying the secret        IF_DEPTH values
//   Total:  256 * IF_DEPTH traces  (default 256*16 = 4,096, fast)
//
// Use +SECRET=wt to switch the secret to FL_GB bytes instead:
//   secret  = one weight byte in FL_GB (address 0)        256 values
//   context = FL_GB address                           FL_DEPTH values
//   Total:  256 * FL_DEPTH traces  (default 256*16 = 4,096)
//
// Protocol per trace:
//   1. Write background to all GB locations (untriggered).
//   2. Write the secret byte to the context address.
//   3. Pulse start; capture the entire start→done transaction.
//
// DUT subsystem: same as tb_tvla_loadctrl.sv (no systolic array).
//
// Compile-time knobs:
//   N           default 8
//   ARRAY_ROWS  default 4
//   ARRAY_COLS  default 4
//   WAVES       default 4
//=====================================================================
module tb_qif_loadctrl;

    parameter N          = 8;
    parameter ARRAY_ROWS = 4;
    parameter ARRAY_COLS = 4;
    parameter WAVES      = 4;

    localparam IF_DEPTH  = ARRAY_ROWS * WAVES;
    localparam FL_DEPTH  = ARRAY_ROWS * ARRAY_COLS;
    localparam IF_ADDR_W = (IF_DEPTH <= 1) ? 1 : $clog2(IF_DEPTH);
    localparam FL_ADDR_W = (FL_DEPTH <= 1) ? 1 : $clog2(FL_DEPTH);
    localparam WADDR_W   = (WAVES    <= 1) ? 1 : $clog2(WAVES);

    localparam MAX_CYCLES = 256;
    localparam real CLK_NS = 10.0;

    reg clk = 1'b0;
    reg reset_n, start;
    wire done;

    // IF_GB write port (TB-driven)
    reg                  if_wr_en;
    reg [IF_ADDR_W-1:0]  if_wr_addr;
    reg [N-1:0]          if_wr_data;

    // FL_GB write port (TB-driven)
    reg                  fl_wr_en;
    reg [FL_ADDR_W-1:0]  fl_wr_addr;
    reg [N-1:0]          fl_wr_data;

    wire                   if_rd_en;
    wire [IF_ADDR_W-1:0]   if_rd_addr;
    wire [N-1:0]           if_rd_data;

    wire                   fl_rd_en;
    wire [FL_ADDR_W-1:0]   fl_rd_addr;
    wire [N-1:0]           fl_rd_data;

    wire [ARRAY_ROWS-1:0]         row_wr_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] row_wr_addr_flat;
    wire [N-1:0]                  row_wr_data;

    wire                      wt_load;
    wire [ARRAY_COLS*N-1:0]   wt_flat;

    wire stream_start;
    wire compute_done;

    wire [ARRAY_ROWS-1:0]         act_rd_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] act_rd_addr_flat;
    wire [ARRAY_ROWS-1:0]         act_valid;
    wire [ARRAY_ROWS*N-1:0]       act_flat;

    wire [ARRAY_COLS-1:0]         valid_sum_out  = {ARRAY_COLS{1'b0}};
    wire [ARRAY_COLS-1:0]         out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;
    wire                          stream_busy;

    // ---- IF_GB ----
    (* dont_touch = "yes" *)
    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (IF_DEPTH),
        .GB_ADDR_WIDTH (IF_ADDR_W)
    ) u_if_gb (
        .clk(clk), .wr_en(if_wr_en), .wr_addr(if_wr_addr), .wr_data(if_wr_data),
        .rd_en(if_rd_en), .rd_addr(if_rd_addr), .rd_data(if_rd_data)
    );

    // ---- FL_GB ----
    (* dont_touch = "yes" *)
    global_buffer #(
        .GB_WORD_WIDTH (N),
        .GB_DEPTH      (FL_DEPTH),
        .GB_ADDR_WIDTH (FL_ADDR_W)
    ) u_fl_gb (
        .clk(clk), .wr_en(fl_wr_en), .wr_addr(fl_wr_addr), .wr_data(fl_wr_data),
        .rd_en(fl_rd_en), .rd_addr(fl_rd_addr), .rd_data(fl_rd_data)
    );

    // ---- load_controller ----
    (* dont_touch = "yes" *)
    load_controller #(
        .N(N), .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS), .WAVES(WAVES)
    ) u_lc (
        .clk(clk), .reset_n(reset_n), .start(start), .done(done),
        .if_rd_en(if_rd_en), .if_rd_addr(if_rd_addr), .if_rd_data(if_rd_data),
        .row_wr_en(row_wr_en), .row_wr_addr_flat(row_wr_addr_flat),
        .row_wr_data(row_wr_data),
        .fl_rd_en(fl_rd_en), .fl_rd_addr(fl_rd_addr), .fl_rd_data(fl_rd_data),
        .wt_load(wt_load), .wt_flat(wt_flat),
        .stream_start(stream_start), .compute_done(compute_done)
    );

    // ---- Per-row activation scratchpads ----
    genvar gr;
    generate
        for (gr = 0; gr < ARRAY_ROWS; gr = gr + 1) begin : g_spad
            scratchpad #(.DATA_WIDTH(N), .SPAD_DEPTH(WAVES)) u_spad (
                .clk(clk),
                .wr_en(row_wr_en[gr]),
                .wr_addr(row_wr_addr_flat[gr*WADDR_W +: WADDR_W]),
                .wr_data(row_wr_data),
                .rd_en(act_rd_en[gr]),
                .rd_addr(act_rd_addr_flat[gr*WADDR_W +: WADDR_W]),
                .rd_data(act_flat[gr*N +: N])
            );
        end
    endgenerate

    // ---- address_generator ----
    (* dont_touch = "yes" *)
    address_generator #(
        .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS), .WAVES(WAVES)
    ) u_ag (
        .clk(clk), .reset_n(reset_n),
        .stream_start(stream_start), .stream_busy(stream_busy),
        .compute_done(compute_done),
        .act_rd_en(act_rd_en), .act_rd_addr_flat(act_rd_addr_flat),
        .act_valid(act_valid),
        .valid_sum_out(valid_sum_out),
        .out_wr_en(out_wr_en), .out_wr_addr_flat(out_wr_addr_flat)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    string SECRET;
    integer si, ki, i, cnt;
    reg [N-1:0] sv;
    reg [N-1:0] bg_if [0:IF_DEPTH-1];
    reg [N-1:0] bg_fl [0:FL_DEPTH-1];

    // ---- helpers ----
    task write_if_gb_bg;
        integer ii;
        begin
            for (ii = 0; ii < IF_DEPTH; ii = ii + 1) begin
                @(negedge clk);
                if_wr_en = 1'b1; if_wr_addr = ii[IF_ADDR_W-1:0];
                if_wr_data = bg_if[ii]; @(posedge clk);
            end
            @(negedge clk); if_wr_en = 1'b0;
        end
    endtask

    task write_fl_gb_bg;
        integer ii;
        begin
            for (ii = 0; ii < FL_DEPTH; ii = ii + 1) begin
                @(negedge clk);
                fl_wr_en = 1'b1; fl_wr_addr = ii[FL_ADDR_W-1:0];
                fl_wr_data = bg_fl[ii]; @(posedge clk);
            end
            @(negedge clk); fl_wr_en = 1'b0;
        end
    endtask

    task wait_done;
        begin
            cnt = 0;
            while (!done && cnt < MAX_CYCLES) begin
                @(posedge clk); cnt = cnt + 1;
            end
        end
    endtask

    initial begin
        qif_get_config("qif_loadctrl", 1);
        if (!$value$plusargs("SECRET=%s", SECRET)) SECRET = "act";

        if (SECRET == "wt")
            qif_total = 256 * FL_DEPTH;
        else
            qif_total = 256 * IF_DEPTH;

        for (i = 0; i < IF_DEPTH; i = i + 1) bg_if[i] = rand_i8(0);
        for (i = 0; i < FL_DEPTH; i = i + 1) bg_fl[i] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_lc);
        $dumpvars(0, u_ag);
        for (i = 0; i < IF_DEPTH && i < 64; i = i + 1)
            $dumpvars(1, u_if_gb.u_mem.mem[i]);
        for (i = 0; i < FL_DEPTH && i < 64; i = i + 1)
            $dumpvars(1, u_fl_gb.u_mem.mem[i]);
        for (i = 0; i < WAVES; i = i + 1) begin
            $dumpvars(1, g_spad[0].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[1].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[2].u_spad.u_mem.mem[i]);
            $dumpvars(1, g_spad[3].u_spad.u_mem.mem[i]);
        end

        qif_open_meta("load_controller", CLK_NS, MAX_CYCLES, qif_total);
        $display("[QIF] loadctrl secret=%0s total=%0d traces", SECRET, qif_total);

        reset_n  = 1'b0; start = 1'b0;
        if_wr_en = 1'b0; if_wr_addr = {IF_ADDR_W{1'b0}}; if_wr_data = {N{1'b0}};
        fl_wr_en = 1'b0; fl_wr_addr = {FL_ADDR_W{1'b0}}; fl_wr_data = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        // Determine iteration bounds
        begin : iter
            integer ctx_max;
            ctx_max = (SECRET == "wt") ? FL_DEPTH : IF_DEPTH;

            for (ki = 0; ki < ctx_max; ki = ki + 1) begin
                for (si = 0; si < 256; si = si + 1) begin
                    if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                    if (qif_in_slice(qif_idx)) begin
                        sv = si[N-1:0];

                        // Write background to all locations (untriggered)
                        write_if_gb_bg;
                        write_fl_gb_bg;

                        // Overwrite the secret location
                        if (SECRET == "wt") begin
                            @(negedge clk);
                            fl_wr_en = 1'b1; fl_wr_addr = ki[FL_ADDR_W-1:0];
                            fl_wr_data = sv; @(posedge clk);
                            @(negedge clk); fl_wr_en = 1'b0;
                        end else begin
                            @(negedge clk);
                            if_wr_en = 1'b1; if_wr_addr = ki[IF_ADDR_W-1:0];
                            if_wr_data = sv; @(posedge clk);
                            @(negedge clk); if_wr_en = 1'b0;
                        end

                        repeat (4) @(posedge clk);

                        // Capture: start -> done
                        @(negedge clk); start = 1'b1;
                        @(posedge clk);
                        trace_t0 = $realtime;
                        @(negedge clk); start = 1'b0;
                        wait_done;
                        @(posedge clk);
                        qif_trace_end(si, $signed(sv), ki, ki);
                        qif_progress(qif_idx, qif_total);

                        repeat (4) @(posedge clk);
                    end
                    qif_idx = qif_idx + 1;
                end
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
