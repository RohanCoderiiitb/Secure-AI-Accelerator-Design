`timescale 1ns/1ps
//=====================================================================
// tb_qif_addrgen.sv -- EXHAUSTIVE QIF capture for address_generator
//                      (with per-row activation scratchpads).
//
// The address_generator sequences addresses deterministically; its
// own state is data-independent.  The measurable information channel
// comes from the activation data it forwards: once the scratchpad is
// loaded, act_valid gates act_flat values onto the bus, and any
// switching there is data-dependent.
//
// Enumeration space:
//   secret  = one activation byte (the value in spad slot 0 of one row)
//                                                         256 values
//   context = row index (which scratchpad holds the secret)
//                                                   ARRAY_ROWS values
//   Total:  256 * ARRAY_ROWS traces (default 256*4 = 1024, fast)
//
// Other spad entries hold a fixed background.  After each trace the
// target entry is restored to the background so successive traces
// share the same initial SRAM state.
//
// Compile-time knobs:
//   ARRAY_ROWS  default 4
//   ARRAY_COLS  default 4
//   WAVES       default 4
//   N           default 8
//=====================================================================
module tb_qif_addrgen;

    parameter ARRAY_ROWS = 4;
    parameter ARRAY_COLS = 4;
    parameter WAVES      = 4;
    parameter N          = 8;

    localparam WADDR_W = (WAVES <= 1) ? 1 : $clog2(WAVES);
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = ARRAY_ROWS + WAVES + 2;
    localparam FLUSH   = 4;

    reg  clk = 1'b0;
    reg  reset_n;
    reg  stream_start;

    wire [ARRAY_ROWS-1:0]         act_rd_en;
    wire [ARRAY_ROWS*WADDR_W-1:0] act_rd_addr_flat;
    wire [ARRAY_ROWS-1:0]         act_valid;

    wire [ARRAY_COLS-1:0] valid_sum_out = {ARRAY_COLS{1'b0}};
    wire [ARRAY_COLS-1:0] out_wr_en;
    wire [ARRAY_COLS*WADDR_W-1:0] out_wr_addr_flat;
    wire                  stream_busy, compute_done;

    (* dont_touch = "yes" *)
    address_generator #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .WAVES      (WAVES)
    ) u_dut (
        .clk              (clk),
        .reset_n          (reset_n),
        .stream_start     (stream_start),
        .stream_busy      (stream_busy),
        .compute_done     (compute_done),
        .act_rd_en        (act_rd_en),
        .act_rd_addr_flat (act_rd_addr_flat),
        .act_valid        (act_valid),
        .valid_sum_out    (valid_sum_out),
        .out_wr_en        (out_wr_en),
        .out_wr_addr_flat (out_wr_addr_flat)
    );

    // Per-row activation scratchpads
    reg  [ARRAY_ROWS-1:0]         spad_wr_en;
    reg  [ARRAY_ROWS*WADDR_W-1:0] spad_wr_addr_flat;
    reg  [N-1:0]                  spad_wr_data;
    wire [ARRAY_ROWS*N-1:0]       act_flat;

    genvar gr;
    generate
        for (gr = 0; gr < ARRAY_ROWS; gr = gr + 1) begin : g_spad
            scratchpad #(.DATA_WIDTH(N), .SPAD_DEPTH(WAVES)) u_spad (
                .clk     (clk),
                .wr_en   (spad_wr_en[gr]),
                .wr_addr (spad_wr_addr_flat[gr*WADDR_W +: WADDR_W]),
                .wr_data (spad_wr_data),
                .rd_en   (act_rd_en[gr]),
                .rd_addr (act_rd_addr_flat[gr*WADDR_W +: WADDR_W]),
                .rd_data (act_flat[gr*N +: N])
            );
        end
    endgenerate

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    reg [N-1:0] bg [0:ARRAY_ROWS-1][0:WAVES-1];

    integer si, ki, r, w;
    reg [N-1:0] sv;

    // Write a single word to one row's spad
    task spad_write(input integer row, input integer wave, input [N-1:0] val);
        begin
            @(negedge clk);
            spad_wr_en                              = {ARRAY_ROWS{1'b0}};
            spad_wr_en[row]                         = 1'b1;
            spad_wr_addr_flat[row*WADDR_W +: WADDR_W] = wave[WADDR_W-1:0];
            spad_wr_data = val;
            @(posedge clk);
            @(negedge clk);
            spad_wr_en = {ARRAY_ROWS{1'b0}};
        end
    endtask

    initial begin
        qif_get_config("qif_addrgen", ARRAY_ROWS);
        qif_total = 256 * ARRAY_ROWS;

        // Seed background tile
        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            for (w = 0; w < WAVES; w = w + 1)
                bg[r][w] = rand_i8(0);

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            for (w = 0; w < WAVES; w = w + 1) begin
                case (r)
                    0: $dumpvars(1, g_spad[0].u_spad.u_mem.mem[w]);
                    1: $dumpvars(1, g_spad[1].u_spad.u_mem.mem[w]);
                    2: $dumpvars(1, g_spad[2].u_spad.u_mem.mem[w]);
                    3: $dumpvars(1, g_spad[3].u_spad.u_mem.mem[w]);
                    default: ;
                endcase
            end

        qif_open_meta("address_generator", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] addrgen exhaustive: 256 secrets x %0d contexts = %0d traces",
                 ARRAY_ROWS, qif_total);

        reset_n      = 1'b0;
        stream_start = 1'b0;
        spad_wr_en   = {ARRAY_ROWS{1'b0}};
        spad_wr_addr_flat = {(ARRAY_ROWS*WADDR_W){1'b0}};
        spad_wr_data = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        // Write full background tile to all spads
        for (r = 0; r < ARRAY_ROWS; r = r + 1)
            for (w = 0; w < WAVES; w = w + 1)
                spad_write(r, w, bg[r][w]);

        for (ki = 0; ki < ARRAY_ROWS; ki = ki + 1) begin
            for (si = 0; si < 256; si = si + 1) begin
                if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
                if (qif_in_slice(qif_idx)) begin
                    sv = si[N-1:0];

                    // Write the secret byte into slot 0 of the target row (untriggered)
                    spad_write(ki, 0, sv);

                    // Flush any residual state in the generator
                    repeat (FLUSH) @(posedge clk);

                    // Capture window: pulse stream_start, observe CAPTURE cycles
                    @(negedge clk);
                    stream_start = 1'b1;
                    @(posedge clk);
                    trace_t0 = $realtime;
                    @(negedge clk);
                    stream_start = 1'b0;
                    repeat (CAPTURE - 1) @(posedge clk);
                    qif_trace_end(si, $signed(sv), ki, ki);
                    qif_progress(qif_idx, qif_total);

                    // Quiesce and restore the target spad slot to background
                    repeat (FLUSH) @(posedge clk);
                    spad_write(ki, 0, bg[ki][0]);
                end
                qif_idx = qif_idx + 1;
            end
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
