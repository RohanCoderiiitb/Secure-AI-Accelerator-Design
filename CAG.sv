module vpe_cag #(
    parameter X    = 4,                 // number of subbanks / lanes / CAGs / MACs
    parameter SUBW = 8,                 // bits per subbank bitmap (e.g. IC_B/X = 32/4)
    parameter AW   = 3                  // clog2(SUBW): position / address width
)(
    input  wire                    clk,
    input  wire                    rst_n,
    input  wire [SUBW-1:0]          csb [0:X-1],
    input  wire [SUBW-1:0]          sel_if_bmp [0:X-1],
    input  wire [SUBW-1:0]          fl_sp_bmp [0:X-1],

    // ---------------------------------------------------------------------
    // Control signals (from PE FSM / per-layer Config descriptor)
    // ---------------------------------------------------------------------
    input  wire                    round_load,       // pulse: snapshot CSB -> "remaining" regs, start of round
    input  wire                    round_pop,        // pulse: consume current non-zero pair, advance to next
    output wire [X*AW-1:0]         if_ra,            // flattened: {IF_RA3,IF_RA2,IF_RA1,IF_RA0}
    output wire [X*AW-1:0]         fl_ra,            // flattened: {FL_RA3,FL_RA2,FL_RA1,FL_RA0}
    output wire [X-1:0]            ra_valid,         // 1 = (if_ra[i],fl_ra[i]) is a valid non-zero pair this cycle
    output wire [X-1:0]            lane_done         // 1 = lane i has no more non-zero pairs left this round
);

 // finding the prefix matrix for the rank computation
    reg [AW-1:0] prefix_if [0:X-1][0:SUBW-1];
    reg [AW-1:0] prefix_fl [0:X-1][0:SUBW-1];
 
    integer k;
    integer p;
    reg [AW-1:0] rank_if, rank_fl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < X; k = k + 1)
                for (p = 0; p < SUBW; p = p + 1) begin
                    prefix_if[k][p] <= {AW{1'b0}};
                    prefix_fl[k][p] <= {AW{1'b0}};
                end
        end else if (round_load) begin
            for (k = 0; k < X; k = k + 1) begin
                rank_if = {AW{1'b0}};
                rank_fl = {AW{1'b0}};
                for (p = 0; p < SUBW; p = p + 1) begin
                    prefix_if[k][p] <= rank_if;                 // rank BEFORE adding bit p
                    prefix_fl[k][p] <= rank_fl;
                    rank_if = rank_if + sel_if_bmp[k][p];        // then fold bit p in
                    rank_fl = rank_fl + fl_sp_bmp[k][p];
                end
            end
        end
    end

    // Snapshot each lane's candidate bits for the current round. The read
    // path below scans this register so round_pop advances the same state it
    // is reading.
    reg [SUBW-1:0] remaining [0:X-1];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < X; k = k + 1)
                remaining[k] <= {SUBW{1'b0}};
        end else if (round_load) begin
            for (k = 0; k < X; k = k + 1)
                remaining[k] <= csb[k];
        end else if (round_pop) begin
            for (k = 0; k < X; k = k + 1) begin
                for (p = 0; p < SUBW; p = p + 1) begin
                    if (remaining[k][p]) begin
                        remaining[k][p] <= 1'b0;
                        break;
                    end
                end
            end
        end
    end

    reg [X-1:0] scan_found;
    reg [AW-1:0] scan_pos [0:X-1];
    always @* begin
        scan_found = {X{1'b0}};
        for (k = 0; k < X; k = k + 1) begin
            scan_pos[k] = {AW{1'b0}};
            for (p = 0; p < SUBW; p = p + 1) begin
                if (!scan_found[k] && remaining[k][p]) begin
                    scan_pos[k] = p;
                    scan_found[k] = 1'b1;
                end
            end
        end
    end
    
    genvar gi;
    generate
        for (gi = 0; gi < X; gi = gi + 1) begin : ADDR_MUX_OUT
            assign if_ra[gi*AW +: AW] = prefix_if[gi][scan_pos[gi]];
            assign fl_ra[gi*AW +: AW] = prefix_fl[gi][scan_pos[gi]];
            assign ra_valid[gi]       = scan_found[gi];
            assign lane_done[gi]      = ~scan_found[gi]; //tells the module there might still be an unused 1
        end
    endgenerate
endmodule