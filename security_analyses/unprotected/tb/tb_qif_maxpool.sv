`timescale 1ns/1ps
//=====================================================================
// tb_qif_maxpool.v -- EXHAUSTIVE QIF for the maxpool unit.
//
// WIN_LEN=2 gives a fully enumerable window: 2^16 = 65,536 traces.
// WIN_LEN=3 is 2^24 = 16.8M -- about 2.5 days and 42 GB, feasible
// overnight with FST streaming. WIN_LEN=4 is 2^32 and is not.
//
// SECRET=win   the full window contents  -- input privacy
// SECRET=len   win_len itself            -- TOPOLOGY (pooling geometry
//              is architecture, exactly what CSI NN reconstructs)
//=====================================================================
module tb_qif_maxpool;
    localparam N=8, CW=5;
    localparam real CLK_NS = 10.0;

    reg clk=1'b0, reset_n, valid_in;
    reg [CW-1:0] win_len;
    reg signed [N-1:0] x_in;
    wire valid_out; wire signed [N-1:0] y_out;

    (* dont_touch = "yes" *)
    maxpool_unit #(.N(N), .CW(CW)) u_dut (
        .clk(clk), .reset_n(reset_n), .valid_in(valid_in),
        .win_len(win_len), .x_in(x_in),
        .valid_out(valid_out), .y_out(y_out));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer WLEN, CAPTURE, FLUSH, si, j, nsec;
    string SECRET;
    reg signed [N-1:0] wvals [0:7];

    initial begin
        qif_get_config("qif_maxpool", 1);
        if (!$value$plusargs("SECRET=%s",  SECRET)) SECRET = "win";
        if (!$value$plusargs("WIN_LEN=%d", WLEN))   WLEN   = 2;
        CAPTURE = WLEN + 3; FLUSH = 2*WLEN;   // fill, y_out latch, drain
        win_len = WLEN[CW-1:0];
        nsec = 1 << (8*WLEN);
        qif_total = nsec;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        qif_open_meta("maxpool_unit", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] WIN_LEN=%0d exhaustive window: %0d traces", WLEN, qif_total);

        reset_n=0; valid_in=0; x_in=0;
        repeat (4) @(posedge clk); reset_n=1; repeat (4) @(posedge clk);

        for (si = 0; si < nsec; si = si + 1) begin
            if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
            if (qif_in_slice(qif_idx)) begin
                for (j = 0; j < WLEN; j = j + 1)
                    wvals[j] = (si >> (8*j)) & 8'hFF;   // odometer over window

                @(negedge clk); valid_in=0; x_in=0;
                repeat (FLUSH) @(posedge clk);
                for (j = 0; j < WLEN; j = j + 1) begin
                    @(negedge clk); x_in = wvals[j]; valid_in = 1'b1;
                    @(posedge clk);
                    if (j == 0) trace_t0 = $realtime;
                end
                @(negedge clk); valid_in=0; x_in=0;
                repeat (CAPTURE-WLEN) @(posedge clk);   // latch y_out, drain
                if (SECRET == "len") qif_trace_end(WLEN, WLEN, si, si);
                else                 qif_trace_end(si, si, 0, 0);
                qif_progress(qif_idx, qif_total);
            end
            qif_idx = qif_idx + 1;
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
