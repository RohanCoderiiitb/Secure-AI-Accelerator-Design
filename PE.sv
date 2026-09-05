// =============================================================================
// PE.sv
//
// Top-level Processing Element. Wires together:
//
//   IF/FL SP BMP RF, CD data  --> routing_inside_PE --> if_data[i], fl_data[i]
//        (bitmaps + CAG + address-aware mux + compressed-data read, per lane)
//                                          |
//                                          v
//                          X x baugh_wooley_multiplier   (4x MAC multiply stage)
//                                          |
//                                          v
//                          per-lane psum accumulator      (the "+" in 4xMAC)
//                                          |
//                                          v
//        V x V: Adder Tree sums all X lanes -> ONE OF point   (ICs of same OC)
//        M x M: lanes stay separate         -> X OF points    (ICs of diff OC)
//
// This module only performs the wiring + accumulation described above; the
// routing datapath (CAG, sparsity RFs, mux) lives in routing_inside_PE.sv /
// CAG.sv, and the raw multiply primitive lives in multiplier.v. Nothing here
// duplicates that logic.
// =============================================================================

module pe_top #(
    parameter X     = 4,   // lanes / subbanks / MACs (matches routing_inside_PE)
    parameter SUBW  = 8,   // bits per sparsity-bitmap subbank
    parameter AW    = 3,   // clog2(SUBW): CD RF address width
    parameter SELW  = 2,   // clog2(X): if_select width
    parameter DATAW = 8,   // signed width of one IF/FL compressed element
    parameter PSUMW = 24   // accumulator width (generous headroom over 2*DATAW)
)(
    input  wire                    clk,
    input  wire                    rst_n,

    // ---- Bitmap RF loads (pass-through to routing_inside_PE) --------------
    input  wire [X-1:0]            if_bmp_wr_en,
    input  wire [X*SUBW-1:0]       if_bmp_wr_data,
    input  wire [X-1:0]            fl_bmp_wr_en,
    input  wire [X*SUBW-1:0]       fl_bmp_wr_data,

    // ---- Compressed IF/FL data content (pass-through) ----------------------
    input  wire [X*SUBW*DATAW-1:0] if_cd_data,
    input  wire [X*SUBW*DATAW-1:0] fl_cd_data,

    // ---- Schedule / Config -------------------------------------------------
    input  wire                    mode_mxm,   // 0 = V x V (sum lanes), 1 = M x M (keep separate)
    input  wire [SELW-1:0]         if_select,

    input  wire                    of_clear,   // pulse: start accumulating a fresh OF point / round

    // ---- Results -------------------------------------------------------
    output wire signed [PSUMW-1:0] of_point_vxv,          // combined OF point, meaningful when mode_mxm==0
    output wire signed [PSUMW-1:0] of_point_mxm [0:X-1],   // per-lane OF points, meaningful when mode_mxm==1
    output wire                    round_done              // all lanes have exhausted this round's CSB
);

    // -------------------------------------------------------------------
    // Routing datapath: bitmaps -> CAG -> address-aware mux -> compressed
    // IF/FL data, one (if_data, fl_data) pair per lane per valid cycle.
    // -------------------------------------------------------------------
    wire [X*AW-1:0]    if_ra, fl_ra;         // exposed for debug/trace if needed
    wire [X-1:0]        ra_valid;
    wire [X-1:0]        lane_done;
    wire [X*DATAW-1:0]  if_data_flat, fl_data_flat;

    routing_inside_PE #(
        .X(X), .SUBW(SUBW), .AW(AW), .SELW(SELW), .DATAW(DATAW)
    ) u_routing (
        .clk(clk),
        .rst_n(rst_n),
        .if_bmp_wr_en(if_bmp_wr_en),
        .if_bmp_wr_data(if_bmp_wr_data),
        .fl_bmp_wr_en(fl_bmp_wr_en),
        .fl_bmp_wr_data(fl_bmp_wr_data),
        .if_cd_data(if_cd_data),
        .fl_cd_data(fl_cd_data),
        .mode_mxm(mode_mxm),
        .if_select(if_select),
        .if_ra(if_ra),
        .fl_ra(fl_ra),
        .ra_valid(ra_valid),
        .lane_done(lane_done),
        .if_data(if_data_flat),
        .fl_data(fl_data_flat)
    );

    assign round_done = &lane_done;

    // Unflatten per-lane compressed data
    wire [DATAW-1:0] if_data [0:X-1];
    wire [DATAW-1:0] fl_data [0:X-1];
    genvar gu;
    generate
        for (gu = 0; gu < X; gu = gu + 1) begin : UNFLAT
            assign if_data[gu] = if_data_flat[gu*DATAW +: DATAW];
            assign fl_data[gu] = fl_data_flat[gu*DATAW +: DATAW];
        end
    endgenerate

    // -------------------------------------------------------------------
    // 4x MAC multiply stage: one Baugh-Wooley signed multiplier per lane.
    // Combinational; only the lanes with ra_valid[i] this cycle produce a
    // meaningful, wanted product (see accumulate stage below).
    // -------------------------------------------------------------------
    wire [2*DATAW-1:0] product [0:X-1];
    generate
        for (gu = 0; gu < X; gu = gu + 1) begin : MULT
            baugh_wooley_multiplier #(.N(DATAW)) u_mult (
                .x(if_data[gu]),
                .y(fl_data[gu]),
                .p(product[gu])
            );
        end
    endgenerate

    // -------------------------------------------------------------------
    // Per-lane psum accumulator (the "+" half of each MAC). Cleared by
    // of_clear at the start of a fresh OF point / round; accumulates one
    // more product every cycle that lane reports ra_valid.
    // -------------------------------------------------------------------
    reg signed [PSUMW-1:0] psum [0:X-1];
    integer m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (m = 0; m < X; m = m + 1)
                psum[m] <= {PSUMW{1'b0}};
        end else begin
            for (m = 0; m < X; m = m + 1) begin
                if (of_clear)
                    psum[m] <= {PSUMW{1'b0}};
                else if (ra_valid[m])
                    psum[m] <= psum[m] + $signed(product[m]);
            end
        end
    end

    // -------------------------------------------------------------------
    // Adder Tree / OF RF stage:
    //   V x V  -> all X lanes are ICs of the SAME OC: sum them into one
    //             combined OF point (this is FLEXNN's intra-PE adder tree).
    //   M x M  -> each lane is a DIFFERENT OC: no cross-lane summing, each
    //             lane's own accumulator IS its OF point.
    // -------------------------------------------------------------------
    integer s;
    reg signed [PSUMW-1:0] vxv_sum;
    always @* begin
        vxv_sum = {PSUMW{1'b0}};
        for (s = 0; s < X; s = s + 1)
            vxv_sum = vxv_sum + psum[s];
    end
    assign of_point_vxv = vxv_sum;

    generate
        for (gu = 0; gu < X; gu = gu + 1) begin : OF_MXM
            assign of_point_mxm[gu] = psum[gu];
        end
    endgenerate

endmodule