// =============================================================================
// PE.sv  -  Versatile Processing Element (VPE)  [core datapath]
// FlexNN: A Dataflow-aware Flexible Deep Learning Accelerator
//
// Reference: Figure 4 (Part 2) and Figure 5 of the FlexNN paper.
//
// This file implements the four foundational structures inside each VPE:
//
//   1. IF CD RF  -  Compressed IF data register files (X subbanks, double-buffered).
//                   Written by the Load FSM; MAC reads from the shadow bank.
//
//   2. FL CD RF  -  Compressed FL (weight) data register files (X subbanks,
//                   double-buffered). Same write/read split as IF CD RF.
//
//   3. Sparsity + CAG path  -  Instantiates routing_inside_PE, which holds the
//                   IF/FL SP BMP RFs, the IF-Select MUX (V x V / M x M), the
//                   two-sided combined sparsity logic (CSB), and the CAG units.
//                   Outputs the non-zero IF/FL compressed values and read
//                   addresses that drive the 4x MAC unit.
//
//   4. PSumX / PSumY accumulators + OF RF  -  Per-lane ACCW-bit accumulator
//                   registers, a double-buffered OF RF (active written by MAC,
//                   shadow read by drain), and an internal OF write-pointer
//                   counter that advances on each of_wr_en pulse.
//
//   5. External psum MUX  -  The three MUXes and final (+) adder from
//                   Fig 4 Part 2: en_ext_psum gates psum_in, accum_Nbr selects
//                   the base operand, the adder combines them, and psum_out
//                   forwards the result to the right/top FPA neighbour.
//
// Intentionally NOT included (deferred):
//   - Eltwise unit  (will be added later)
//   - Pooling unit  (will be added later)
// =============================================================================

`default_nettype none


module vpe #(
    parameter X     = 4,   // Number of lanes / subbanks / MACs
    parameter SUBW  = 8,   // Entries per subbank  (= IC_B / X)
    parameter AW    = 3,   // clog2(SUBW): address bits into compressed RF
    parameter SELW  = 2,   // clog2(X):   if_select width for M x M mode
    parameter DATAW = 8,   // Compressed element width (INT8)
    parameter PRODW = 16,  // MAC product width (2 x DATAW)
    parameter ACCW  = 32   // Accumulator / psum / OF width
)(
    // -------------------------------------------------------------------------
    // Clock and active-low synchronous reset
    // -------------------------------------------------------------------------
    input  wire                      clk,
    input  wire                      rst_n,

    // -------------------------------------------------------------------------
    // Config descriptor  (loaded by the per-column Control Block each layer)
    // -------------------------------------------------------------------------
    input  wire                      mode_mxm,    // 0 = V x V  |  1 = M x M
    input  wire [SELW-1:0]          if_select,   // Active IF subbank index in M x M

    // Psum routing controls (Fig 4 Part 2 three-MUX structure)
    input  wire                      accum_dir,   // 0 = forward psum right  |  1 = top
    input  wire                      accum_Nbr,   // 0 = use internal OF     |  1 = use neighbour psum
    input  wire                      en_ext_psum, // 1 = add external psum contribution

    // -------------------------------------------------------------------------
    // PE FSM control  (pulses from the per-column Control Block)
    // -------------------------------------------------------------------------
    // Flush accumulator[k] to the active OF RF at of_wr_ptr[k], then clear and
    // advance the pointer.  Assert one bit per lane independently.
    input  wire [X-1:0]              of_wr_en,

    // Pulse: swap IF/FL banks (active <-> shadow) AND copy OF active -> shadow.
    // Fired when a complete load round is finished and compute can start.
    input  wire                      buf_swap,

    // Pulse: reset all OF write pointers to 0 at the start of a new layer.
    input  wire                      layer_start,

    // -------------------------------------------------------------------------
    // IF CD RF write ports  (from the Load FSM / distribution network)
    //
    // Always written into the ACTIVE bank.
    // X independent subbanks, each with its own write enable and address.
    // -------------------------------------------------------------------------
    input  wire [X-1:0]              if_rf_wr_en,             // per-subbank write enable
    input  wire [X*AW-1:0]          if_rf_wr_addr,           // flattened {WA3,WA2,WA1,WA0}
    input  wire [X*DATAW-1:0]       if_rf_wr_data,           // flattened {D3,D2,D1,D0}

    // -------------------------------------------------------------------------
    // FL CD RF write ports  (from the Load FSM / distribution network)
    // -------------------------------------------------------------------------
    input  wire [X-1:0]              fl_rf_wr_en,
    input  wire [X*AW-1:0]          fl_rf_wr_addr,
    input  wire [X*DATAW-1:0]       fl_rf_wr_data,

    // -------------------------------------------------------------------------
    // Sparsity bitmap write ports  (forwarded directly to routing_inside_PE)
    // -------------------------------------------------------------------------
    input  wire [X-1:0]              if_bmp_wr_en,
    input  wire [X*SUBW-1:0]        if_bmp_wr_data,          // flattened {BMP3..BMP0}
    input  wire [X-1:0]             fl_bmp_wr_en,
    input  wire [X*SUBW-1:0]        fl_bmp_wr_data,

    // -------------------------------------------------------------------------
    // External psum  (from right / top FPA neighbour or SRAM bypass)
    // -------------------------------------------------------------------------
    input  wire [ACCW-1:0]          psum_in,
    output wire [ACCW-1:0]          psum_out,     // combined psum forwarded to neighbour
    output wire                      psum_dir_out, // mirrors accum_dir for FPA wire routing

    // -------------------------------------------------------------------------
    // OF drain output  (reads from shadow OF RF)
    //   drain_rd_addr : entry index 0..SUBW-1, driven by the Local Drain FSM
    //   of_out        : X lanes read simultaneously at the same entry index
    // -------------------------------------------------------------------------
    input  wire [AW-1:0]            drain_rd_addr,
    output wire [X*ACCW-1:0]        of_out,

    // -------------------------------------------------------------------------
    // Status outputs (passed through from routing_inside_PE / CAG)
    // -------------------------------------------------------------------------
    output wire [X-1:0]              ra_valid,     // 1 = non-zero IF/FL pair ready this cycle
    output wire [X-1:0]              lane_done     // 1 = CSB bitmap exhausted for this round
);

// =============================================================================
// LOCAL SIGNAL DECLARATIONS
// =============================================================================

// IF / FL CD RF storage: [bank 0/1][subbank 0..X-1][entry 0..SUBW-1]
// Bank indexing uses if_fl_active_bank to implement the double-buffer.
reg [DATAW-1:0]  if_rf [0:1][0:X-1][0:SUBW-1];
reg [DATAW-1:0]  fl_rf [0:1][0:X-1][0:SUBW-1];

// 1-bit bank selector for the IF/FL double-buffer.
//   if_fl_active_bank = 0  ->  bank-0 is ACTIVE (Load FSM writes here)
//                              bank-1 is SHADOW  (MAC reads here)
//   if_fl_active_bank = 1  ->  bank-1 is ACTIVE, bank-0 is SHADOW
// Toggled by buf_swap.
reg  if_fl_active_bank;

// Flattened shadow-bank buses wired into routing_inside_PE
wire [X*SUBW*DATAW-1:0] if_cd_flat;
wire [X*SUBW*DATAW-1:0] fl_cd_flat;

// Outputs from routing_inside_PE
wire [X*AW-1:0]     if_ra_w;       // read addresses (internally used by routing module)
wire [X*AW-1:0]     fl_ra_w;
wire [X*DATAW-1:0]  if_data_w;    // non-zero compressed IF value per lane (to MAC)
wire [X*DATAW-1:0]  fl_data_w;    // non-zero compressed FL value per lane (to MAC)

// Per-lane operand unpacking
wire [DATAW-1:0]    if_op [0:X-1];
wire [DATAW-1:0]    fl_op [0:X-1];

// Baugh-Wooley multiplier products
wire [PRODW-1:0]    mul_out [0:X-1];

// Products sign-extended to ACCW for accumulation
wire signed [ACCW-1:0] mac_ext [0:X-1];

// OF RF (double-buffered)
//   of_rf_active : written by MAC accumulation flush (of_wr_en)
//   of_rf_shadow : read by Local Drain (of_out / drain_rd_addr)
reg [ACCW-1:0]  of_rf_active [0:X-1][0:SUBW-1];
reg [ACCW-1:0]  of_rf_shadow [0:X-1][0:SUBW-1];

// Per-lane running accumulator and OF write pointer
reg signed [ACCW-1:0]  accumulator [0:X-1];
reg        [AW-1:0]    of_wr_ptr   [0:X-1];

// External psum MUX intermediates
wire signed [ACCW-1:0]  ext_psum_gated;
wire signed [ACCW-1:0]  internal_psum;
wire signed [ACCW-1:0]  selected_base;
wire signed [ACCW-1:0]  final_psum;

// Loop indices for non-generate always blocks
integer k, e;
genvar  gi, gj;

// =============================================================================
// BLOCK 1  -  IF CD RF
//   X subbanks, each SUBW entries deep, DATAW bits wide.
//   Double-buffered with if_fl_active_bank:
//     Write path: Load FSM  ->  if_rf[active_bank][subbank][wr_addr]
//     Read  path: MAC       <-  if_rf[shadow_bank][subbank][rd_addr]  (via flat bus)
//   buf_swap flips active_bank, so freshly loaded data becomes the new shadow
//   on the very next cycle and is immediately readable by the MAC.
// =============================================================================

always @(posedge clk or negedge rst_n) begin : IF_CD_RF_WRITE
    if (!rst_n) begin
        for (k = 0; k < X; k = k + 1)
            for (e = 0; e < SUBW; e = e + 1) begin
                if_rf[0][k][e] <= {DATAW{1'b0}};
                if_rf[1][k][e] <= {DATAW{1'b0}};
            end
    end else begin
        for (k = 0; k < X; k = k + 1)
            if (if_rf_wr_en[k])
                if_rf[if_fl_active_bank][k][ if_rf_wr_addr[k*AW +: AW] ]
                    <= if_rf_wr_data[k*DATAW +: DATAW];
    end
end

// =============================================================================
// BLOCK 2  -  FL CD RF
//   Identical structure to the IF CD RF (BLOCK 1).
//   Shares the same if_fl_active_bank selector and buf_swap toggle.
// =============================================================================

always @(posedge clk or negedge rst_n) begin : FL_CD_RF_WRITE
    if (!rst_n) begin
        for (k = 0; k < X; k = k + 1)
            for (e = 0; e < SUBW; e = e + 1) begin
                fl_rf[0][k][e] <= {DATAW{1'b0}};
                fl_rf[1][k][e] <= {DATAW{1'b0}};
            end
    end else begin
        for (k = 0; k < X; k = k + 1)
            if (fl_rf_wr_en[k])
                fl_rf[if_fl_active_bank][k][ fl_rf_wr_addr[k*AW +: AW] ]
                    <= fl_rf_wr_data[k*DATAW +: DATAW];
    end
end

// --- IF/FL double-buffer bank-select toggle ---
// buf_swap flips which bank is active; the previously active (now shadow) bank
// becomes readable by the MAC on the very next clock edge.
always @(posedge clk or negedge rst_n) begin : BANK_TOGGLE
    if (!rst_n)
        if_fl_active_bank <= 1'b0;
    else if (buf_swap)
        if_fl_active_bank <= ~if_fl_active_bank;
end

// --- Flatten shadow bank -> routing_inside_PE combinationally ---
// The shadow bank index is the complement of if_fl_active_bank.
// Mapping: entry [subbank gi][entry gj] -> flat bit range (gi*SUBW+gj)*DATAW
generate
    for (gi = 0; gi < X; gi = gi + 1) begin : FLATTEN_SHADOW_SUBBANK
        for (gj = 0; gj < SUBW; gj = gj + 1) begin : FLATTEN_SHADOW_ENTRY
            assign if_cd_flat[(gi*SUBW + gj)*DATAW +: DATAW]
                = if_rf[~if_fl_active_bank][gi][gj];
            assign fl_cd_flat[(gi*SUBW + gj)*DATAW +: DATAW]
                = fl_rf[~if_fl_active_bank][gi][gj];
        end
    end
endgenerate

// =============================================================================
// BLOCK 3  -  routing_inside_PE  (sparsity + CAG + address-aware mux)
//
//   Internally implements:
//     - IF SP BMP RF / FL SP BMP RF  (X 1R1W bitmap registers each)
//     - IF-Select MUX: V x V -> lane i uses its own IF SP BMP;
//                      M x M -> all lanes share the broadcast IF SP BMP[if_select]
//     - Two-sided CSB: CSB[i] = selected_IF_bmp[i] & FL_bmp[i]
//     - CAG (x X): scans CSB bitmap, produces rank-based read addresses
//     - CD read:   indexes if_cd_flat/fl_cd_flat with CAG addresses to deliver
//                  the non-zero operand values lane by lane
//
//   Outputs consumed by BLOCK 4:
//     if_data_w / fl_data_w  -  non-zero compressed operands per lane
//     ra_valid               -  1 = a valid non-zero pair is present this cycle
//     lane_done              -  1 = no more non-zero pairs remain in this round
// =============================================================================

routing_inside_PE #(
    .X    (X),
    .SUBW (SUBW),
    .AW   (AW),
    .SELW (SELW),
    .DATAW(DATAW)
) u_routing (
    .clk            (clk),
    .rst_n          (rst_n),
    .if_bmp_wr_en   (if_bmp_wr_en),
    .if_bmp_wr_data (if_bmp_wr_data),
    .fl_bmp_wr_en   (fl_bmp_wr_en),
    .fl_bmp_wr_data (fl_bmp_wr_data),
    .if_cd_data     (if_cd_flat),    // shadow bank of IF CD RF
    .fl_cd_data     (fl_cd_flat),    // shadow bank of FL CD RF
    .mode_mxm       (mode_mxm),
    .if_select      (if_select),
    .if_ra          (if_ra_w),
    .fl_ra          (fl_ra_w),
    .ra_valid       (ra_valid),
    .lane_done      (lane_done),
    .if_data        (if_data_w),
    .fl_data        (fl_data_w)
);

// =============================================================================
// BLOCK 4  -  4x MAC array  (one Baugh-Wooley INT8 x INT8 multiplier per lane)
//
//   Each cycle that ra_valid[k]=1, routing_inside_PE presents the next non-zero
//   (IF, FL) compressed pair for lane k.  The multiplier is purely combinational;
//   the registered accumulation happens in BLOCK 5.
// =============================================================================

// Unpack the per-lane INT8 operands from the flattened bus
generate
    for (gi = 0; gi < X; gi = gi + 1) begin : UNPACK_OPS
        assign if_op[gi] = if_data_w[gi*DATAW +: DATAW];
        assign fl_op[gi] = fl_data_w[gi*DATAW +: DATAW];
    end
endgenerate

// Instantiate one Baugh-Wooley signed multiplier per lane
generate
    for (gi = 0; gi < X; gi = gi + 1) begin : MAC_ARRAY
        baugh_wooley_multiplier #(.N(DATAW)) u_mul (
            .x (if_op[gi]),
            .y (fl_op[gi]),
            .p (mul_out[gi])
        );
    end
endgenerate

// Sign-extend each PRODW-bit product to ACCW bits for the accumulator
generate
    for (gi = 0; gi < X; gi = gi + 1) begin : SIGN_EXT
        assign mac_ext[gi] = {{(ACCW-PRODW){mul_out[gi][PRODW-1]}}, mul_out[gi]};
    end
endgenerate

// =============================================================================
// BLOCK 5  -  PSumX / PSumY accumulators + double-buffered OF RF
//
//   Per lane k:
//
//   Accumulation (ra_valid[k]=1, of_wr_en[k]=0):
//     accumulator[k] += mac_ext[k]   (signed, sign-extended)
//
//   Flush (of_wr_en[k]=1):
//     Case A  ra_valid[k]=0 :  write accumulator[k] to of_rf_active[k][of_wr_ptr[k]]
//     Case B  ra_valid[k]=1 :  write accumulator[k]+mac_ext[k] (last pair + flush)
//     In both cases: clear accumulator[k] to 0, advance of_wr_ptr[k] by 1.
//
//   layer_start:  reset all of_wr_ptr[k] to 0 (priority over of_wr_en increment).
//
//   OF RF double-buffer:
//     of_rf_active : written exclusively by this always block (of_wr_en)
//     of_rf_shadow : written exclusively by the buf_swap always block below
//     of_out       : reads from of_rf_shadow at drain_rd_addr (all X lanes)
// =============================================================================

// --- Accumulator + active OF RF ---
always @(posedge clk or negedge rst_n) begin : ACCUM_OF_RF
    if (!rst_n) begin
        for (k = 0; k < X; k = k + 1) begin
            accumulator[k] <= {ACCW{1'b0}};
            of_wr_ptr[k]   <= {AW{1'b0}};
            for (e = 0; e < SUBW; e = e + 1)
                of_rf_active[k][e] <= {ACCW{1'b0}};
        end
    end else begin
        for (k = 0; k < X; k = k + 1) begin

            // Normal accumulation: valid pair present, no flush this cycle
            if (ra_valid[k] && !of_wr_en[k])
                accumulator[k] <= $signed(accumulator[k]) + $signed(mac_ext[k]);

            // Flush to active OF RF
            if (of_wr_en[k]) begin
                if (ra_valid[k])
                    // Last pair and flush coincide: include mac_ext before writing
                    of_rf_active[k][of_wr_ptr[k]]
                        <= $signed(accumulator[k]) + $signed(mac_ext[k]);
                else
                    // Standard flush of the running accumulator
                    of_rf_active[k][of_wr_ptr[k]] <= accumulator[k];

                accumulator[k] <= {ACCW{1'b0}};           // clear after flush

                if (!layer_start)                          // advance pointer
                    of_wr_ptr[k] <= of_wr_ptr[k] + 1'b1;
            end

            // layer_start resets the write pointer (takes priority over advance)
            if (layer_start)
                of_wr_ptr[k] <= {AW{1'b0}};

        end
    end
end

// --- Shadow OF RF: copy active -> shadow on buf_swap ---
// Kept in its own always block so of_rf_active has exactly one driver.
always @(posedge clk or negedge rst_n) begin : OF_SHADOW_COPY
    if (!rst_n) begin
        for (k = 0; k < X; k = k + 1)
            for (e = 0; e < SUBW; e = e + 1)
                of_rf_shadow[k][e] <= {ACCW{1'b0}};
    end else if (buf_swap) begin
        for (k = 0; k < X; k = k + 1)
            for (e = 0; e < SUBW; e = e + 1)
                of_rf_shadow[k][e] <= of_rf_active[k][e];
    end
end

// Drain read: expose all X lanes at the requested shadow entry simultaneously.
// The Local Drain FSM steps drain_rd_addr from 0 to SUBW-1 to extract all OF points.
generate
    for (gi = 0; gi < X; gi = gi + 1) begin : OF_DRAIN_READ
        assign of_out[gi*ACCW +: ACCW] = of_rf_shadow[gi][drain_rd_addr];
    end
endgenerate

// =============================================================================
// BLOCK 6  -  External psum MUX  (Fig 4 Part 2: three MUXes + final (+) adder)
//
//   Step 1  en_ext_psum gates psum_in:
//             ext_psum_gated = en_ext_psum ? psum_in : 0
//
//   Step 2  accum_Nbr selects the base operand for the adder:
//             selected_base = accum_Nbr ? ext_psum_gated : internal_psum
//             where internal_psum = of_rf_shadow[lane-0][entry-0]
//             (representative first OF point; FLEXTREE handles multi-PE reduction)
//
//   Step 3  Final (+) adder:
//             final_psum = selected_base + ext_psum_gated
//             When en_ext_psum=0: ext_psum_gated=0 -> final_psum = selected_base
//
//   psum_out     : forwarded to the FPA neighbour for cross-PE IC accumulation.
//   psum_dir_out : mirrors accum_dir (0=right, 1=top); the FPA instantiator
//                  connects psum_out to the correct physical neighbour wire.
// =============================================================================

assign ext_psum_gated = en_ext_psum ? $signed(psum_in)         : {ACCW{1'b0}};
assign internal_psum  =               $signed(of_rf_shadow[0][0]);
assign selected_base  = accum_Nbr   ? ext_psum_gated           : internal_psum;
assign final_psum     = $signed(selected_base) + $signed(ext_psum_gated);

assign psum_out     = final_psum;
assign psum_dir_out = accum_dir;

endmodule

`default_nettype wire
