`timescale 1ns/1ps
//=====================================================================
// tb_tvla_mac.v -- TVLA dataset generation for the stand-alone MAC unit
//                  (MLP-style datapath, temporal accumulation).
//
// Capture window covers a full dot-product of length OPS: clr on the
// first operand, accumulate for the rest. The accumulator register is
// the dominant HD contributor and is where weight-dependent leakage
// concentrates.
//=====================================================================
module tb_tvla_mac;

    localparam N    = 8;
    localparam ACCW = 32;                 // minimum width for OPS x INT8xINT8
    localparam real CLK_NS = 10.0;

    localparam OPS     = 8;               // dot-product length
    localparam FLUSH   = 3;
    localparam CAPTURE = OPS;

    reg              clk = 1'b0;
    reg              reset_n, en, clr;
    reg  signed [N-1:0] act, wt;
    wire [ACCW-1:0]  accum;

    (* dont_touch = "yes" *)
    mac_unit #(.N(N), .ACCW(ACCW)) u_dut (
        .clk(clk), .reset_n(reset_n), .en(en), .clr(clr),
        .act(act), .wt(wt), .accum(accum)
    );

    always #(CLK_NS/2.0) clk = ~clk;

    `include "sca_capture.vh"

    reg signed [N-1:0] fix_act [0:OPS-1];
    reg signed [N-1:0] fix_wt  [0:OPS-1];

    integer t, k;
    reg grp, eff;
    reg signed [N-1:0] ra, rw;

    initial begin
        sca_get_config("mac");

        for (k = 0; k < OPS; k = k + 1) begin
            fix_act[k] = rand_i8(0);
            fix_wt [k] = rand_i8(0);
        end

        $dumpfile({OUTDIR, "/", TAG, ".vcd"});
        $dumpvars(0, u_dut);

        sca_open_meta("mac_unit", CLK_NS, CAPTURE);

        reset_n = 1'b0; en = 1'b0; clr = 1'b0;
        act = {N{1'b0}}; wt = {N{1'b0}};
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);

        for (t = 0; t < NTRACES; t = t + 1) begin
            grp = group_sched[t];
            eff = effective_random(grp);

            // ---- flush: zero the accumulator, untriggered ----
            @(negedge clk);
            en = 1'b1; clr = 1'b1; act = {N{1'b0}}; wt = {N{1'b0}};
            @(posedge clk);
            @(negedge clk);
            en = 1'b0; clr = 1'b0;
            repeat (FLUSH-1) @(posedge clk);

            // ---- capture window ----
            for (k = 0; k < OPS; k = k + 1) begin
                @(negedge clk);          // drive off the negedge (see note)
                ra = rand_i8(0);
                rw = rand_i8(0);
                if (!eff) begin ra = fix_act[k]; rw = fix_wt[k]; end

                if (TVLA_TARGET == "act") begin
                    act = ra;         wt = fix_wt[k];
                end else if (TVLA_TARGET == "wt") begin
                    act = fix_act[k]; wt = rw;
                end else begin
                    act = ra;         wt = rw;
                end

                en  = 1'b1;
                clr = (k == 0);       // first MAC of the dot product
                @(posedge clk);
                if (k == 0) sca_trace_begin;
            end
            sca_trace_end(grp);

            @(negedge clk);
            en = 1'b0; clr = 1'b0;
            act = {N{1'b0}}; wt = {N{1'b0}};

            if (t % 500 == 0)
                $display("[SCA] trace %0d / %0d  t=%0t", t, NTRACES, $time);
        end

        repeat (2) @(posedge clk);
        sca_close_meta;
        $finish;
    end

endmodule
