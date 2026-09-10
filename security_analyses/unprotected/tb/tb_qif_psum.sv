`timescale 1ns/1ps
//=====================================================================
// tb_qif_psum.v -- EXHAUSTIVE QIF over the reachable psum_in range.
// Secret is psum_in on lane 0 (privacy: the accumulated dot product).
// Other lanes held at 0 so the channel is attributable to one lane.
// Reachable range +/-2^17 as for requantize: 262,144 traces at step 1.
//=====================================================================
module tb_qif_psum;
    localparam N=8, ACCW=32, COLS=5, DEPTH=32, AW=6;
    localparam real CLK_NS = 10.0;
    localparam CAPTURE = 4, FLUSH = 6;   // read-modify-write on mem[], drain

    reg clk=1'b0, reset_n, tile_start, first_tile, last_tile;
    reg [COLS-1:0] valid_in;
    reg [COLS*ACCW-1:0] psum_in;
    wire [COLS*ACCW-1:0] psum_out; wire [COLS-1:0] valid_out, ovf;

    (* dont_touch = "yes" *)
    psum_accum #(.N(N),.ACCW(ACCW),.COLS(COLS),.DEPTH(DEPTH),.AW(AW)) u_dut (
        .clk(clk), .reset_n(reset_n), .tile_start(tile_start),
        .first_tile(first_tile), .last_tile(last_tile),
        .valid_in(valid_in), .psum_in(psum_in), .psum_out(psum_out),
        .valid_out(valid_out), .ovf(ovf));
    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"
    `include "qif_schedule.vh"

    integer ACC_LO, ACC_HI, ACC_STEP, sv, c;

    initial begin
        qif_get_config("qif_psum", 1);
        if (!$value$plusargs("ACC_LO=%d",  ACC_LO))   ACC_LO   = -131072;
        if (!$value$plusargs("ACC_HI=%d",  ACC_HI))   ACC_HI   =  131071;
        if (!$value$plusargs("ACC_STEP=%d",ACC_STEP)) ACC_STEP = 1;
        qif_total = (ACC_HI - ACC_LO)/ACC_STEP + 1;

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);
        for (c = 0; c < 8; c = c + 1) begin
            $dumpvars(1, u_dut.g_lane[0].mem[c]);   // mem[] needs explicit dump
            $dumpvars(1, u_dut.g_lane[1].mem[c]);
        end
        qif_open_meta("psum_accum", CLK_NS, CAPTURE, qif_total);
        $display("[QIF] psum_in exhaustive over [%0d,%0d] step %0d, %0d traces",
                 ACC_LO, ACC_HI, ACC_STEP, qif_total);

        reset_n=0; tile_start=0; first_tile=0; last_tile=0;
        valid_in=0; psum_in=0;
        repeat (4) @(posedge clk); reset_n=1; repeat (4) @(posedge clk);

        for (sv = ACC_LO; sv <= ACC_HI; sv = sv + ACC_STEP) begin
            if (qif_past_slice(qif_idx)) begin sca_close_meta; $finish; end
            if (qif_in_slice(qif_idx)) begin
                @(negedge clk); valid_in=0; psum_in=0;
                tile_start=0; first_tile=0; last_tile=0;
                repeat (FLUSH) @(posedge clk);
                @(negedge clk);
                psum_in = 0; psum_in[0*ACCW +: ACCW] = sv;
                valid_in = {COLS{1'b1}};
                tile_start = 1'b1; first_tile = 1'b1; last_tile = 1'b1;
                @(posedge clk);
                trace_t0 = $realtime;
                @(negedge clk); valid_in=0; psum_in=0;
                tile_start=0; first_tile=0; last_tile=0;
                repeat (CAPTURE-1) @(posedge clk);
                qif_trace_end(0, sv, 0, 0);
                qif_progress(qif_idx, qif_total);
            end
            qif_idx = qif_idx + 1;
        end
        repeat (2) @(posedge clk); sca_close_meta; $finish;
    end
endmodule
