// =============================================================================
// flexnn_vpe_bmp_addr.v
//
// Scope (maps to Fig. 5 of the FlexNN paper, VPE microarchitecture):
//
//     IF SP BMP RF  --\                                       /--> IF_RA[i] --> (to MAC / IF CD RF, user-handled)
//                       >-- IF-Select Mux --> AND --> CSB[i] -->  CAG[i]
//     FL SP BMP RF  --/        (addr-aware)                   \--> FL_RA[i] --> (to MAC / FL CD RF, user-handled)
//
// This module implements EVERYTHING up to and including address generation:
//   1. IF SP BMP RF / FL SP BMP RF      - X sparsity-bitmap subbank registers each
//   2. IF-Select ("address-aware") mux  - routes IF subbank(s) to lane(s), per V x V / M x M
//   3. Two-sided sparsity accel logic   - CSB[i] = selected_IF_bmp[i] & FL_bmp[i]
//   4. CAG units (x X)                  - find next non-zero position in CSB[i],
//                                          translate position -> compressed RF
//                                          address (rank/popcount), one pop per cycle
//   5. Sparsity-aware Address Mux       - the CAG-generated IF_RA/FL_RA ARE this
//                                          mux's output; see mode-dependent wiring below
//
// NOT implemented here (left for the user, per request):
//   - The actual MAC array (4x MAC)
//   - IF CD RF / FL CD RF storage (this module only produces the READ ADDRESS
//     into those RFs; the user's MAC-side logic is expected to use if_ra/fl_ra
//     to index its own compressed-data memories and perform the multiply)
//   - Load FSM / Circular Buffer / Byte-select modules that fill the bitmap RFs
//
// Modes:
//   mode_mxm = 0  -> V x V  : each lane i uses its OWN IF subbank i (straight
//                     through mux, IC-of-same-OC accumulation, Fig. 6 panel 1)
//   mode_mxm = 1  -> M x M  : all lanes use the SAME broadcast IF subbank
//                     (selected by if_select), each paired with its own FL
//                     subbank (IC-of-different-OC accumulation, Fig. 6 panel 2).
//                     if_select is expected to be advanced by the caller round
//                     by round to sweep through the IC_B (or spatial) subbanks.
//
// Addressing:
//   IF/FL CD RFs are compressed (only non-zero values stored), so the read
//   address for a bit found at position p in a bitmap is NOT p itself, it is
//   the number of set bits before p in that same bitmap (its "rank"). This
//   module computes that rank for both the IF and FL bitmap independently,
//   since in M x M mode the FL bitmap differs per lane even though the IF
//   bitmap is shared, so the two compressed streams can be indexed differently
//   even for the "same" logical position p.
// =============================================================================

module routing_inside_PE#(
    parameter X    = 4,                 // number of subbanks / lanes / CAGs / MACs
    parameter SUBW = 8,                 // bits per subbank bitmap (e.g. IC_B/X = 32/4)
    parameter AW   = 3,                 // clog2(SUBW): position / address width
    parameter SELW = 2,                 // clog2(X): width of if_select
    parameter DATAW = 8                 // compressed IF/FL element width
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---------------------------------------------------------------------
    // Bitmap RF write ports (driven by Load FSM / byte-select logic —
    // upstream of this module, not implemented here)
    // ---------------------------------------------------------------------
    input  wire [X-1:0]            if_bmp_wr_en,
    input  wire [X*SUBW-1:0]       if_bmp_wr_data,   // flattened: {IF3,IF2,IF1,IF0}
    input  wire [X-1:0]            fl_bmp_wr_en,
    input  wire [X*SUBW-1:0]       fl_bmp_wr_data,   // flattened: {FL3,FL2,FL1,FL0}
    input  wire [X*SUBW*DATAW-1:0] if_cd_data,       // flattened by lane, entry, value
    input  wire [X*SUBW*DATAW-1:0] fl_cd_data,

    // ---------------------------------------------------------------------
    // Schedule / Config control (from PE FSM / per-layer Config descriptor)
    // ---------------------------------------------------------------------
    input  wire                    mode_mxm,         // 0 = V x V , 1 = M x M
    input  wire [SELW-1:0]         if_select,        // active IF subbank in M x M mode
    // ---------------------------------------------------------------------
    // Address-aware-mux outputs: one (IF_RA, FL_RA) pair per lane, handed
    // onward to the user's MAC / CD-RF read logic
    // ---------------------------------------------------------------------
    output wire [X*AW-1:0]         if_ra,            // flattened: {IF_RA3,IF_RA2,IF_RA1,IF_RA0}
    output wire [X*AW-1:0]         fl_ra,            // flattened: {FL_RA3,FL_RA2,FL_RA1,FL_RA0}
    output wire [X-1:0]            ra_valid,         // 1 = (if_ra[i],fl_ra[i]) is a valid non-zero pair this cycle
    output wire [X-1:0]            lane_done,        // 1 = lane i has no more non-zero pairs left this round
    output wire [X*DATAW-1:0]      if_data,
    output wire [X*DATAW-1:0]      fl_data
);

    // 1) IF SP BMP RF / FL SP BMP RF  (X x SUBW-bit sparsity bitmap regs)
    reg [SUBW-1:0] if_sp_bmp [0:X-1];
    reg [SUBW-1:0] fl_sp_bmp [0:X-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < X; k = k + 1) begin
                if_sp_bmp[k] <= {SUBW{1'b0}};
                fl_sp_bmp[k] <= {SUBW{1'b0}};
            end
        end else begin
            for (k = 0; k < X; k = k + 1) begin
                if (if_bmp_wr_en[k]) if_sp_bmp[k] <= if_bmp_wr_data[k*SUBW +: SUBW];
                if (fl_bmp_wr_en[k]) fl_sp_bmp[k] <= fl_bmp_wr_data[k*SUBW +: SUBW];
            end
        end
    end

    //    V x V  : lane i reads its own IF subbank i (straight through)
    //    M x M  : every lane reads the SAME subbank if_select (broadcast)
    wire [SUBW-1:0] sel_if_bmp [0:X-1];
    genvar gi;
    generate
        for (gi = 0; gi < X; gi = gi + 1) begin : IF_SELECT_MUX
            assign sel_if_bmp[gi] = mode_mxm ? if_sp_bmp[if_select] : if_sp_bmp[gi];
        end
    endgenerate

    // 3) Two-sided sparsity acceleration logic -> CSB[i]
    wire [SUBW-1:0] csb [0:X-1];
    generate
        for (gi = 0; gi < X; gi = gi + 1) begin : CSB_GEN
            assign csb[gi] = sel_if_bmp[gi] & fl_sp_bmp[gi];
        end
    endgenerate

    reg round_load;
    wire round_pop;
    reg load_pending;

    // Bitmap writes arm a new round; loading is delayed one cycle so the
    // bitmap registers have received their new values.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            round_load   <= 1'b0;
            load_pending <= 1'b0;
        end else begin
            round_load <= load_pending;
            if ((if_bmp_wr_en != {X{1'b0}}) || (fl_bmp_wr_en != {X{1'b0}}))
                load_pending <= 1'b1;
            else if (load_pending)
                load_pending <= 1'b0;
        end
    end

    assign round_pop = !round_load && (|ra_valid);

    vpe_cag #(
        .X(X),
        .SUBW(SUBW),
        .AW(AW)
    ) cag (
        .clk(clk),
        .rst_n(rst_n),
        .csb(csb),
        .sel_if_bmp(sel_if_bmp),
        .fl_sp_bmp(fl_sp_bmp),
        .round_load(round_load),
        .round_pop(round_pop),
        .if_ra(if_ra),
        .fl_ra(fl_ra),
        .ra_valid(ra_valid),
        .lane_done(lane_done)
    );

    genvar data_lane;
    generate
        for (data_lane = 0; data_lane < X; data_lane = data_lane + 1) begin : CD_READ
            assign if_data[data_lane*DATAW +: DATAW] = if_cd_data[(data_lane*SUBW + if_ra[data_lane*AW +: AW])*DATAW +: DATAW];
            assign fl_data[data_lane*DATAW +: DATAW] = fl_cd_data[(data_lane*SUBW + fl_ra[data_lane*AW +: AW])*DATAW +: DATAW];
        end
    endgenerate
    
endmodule