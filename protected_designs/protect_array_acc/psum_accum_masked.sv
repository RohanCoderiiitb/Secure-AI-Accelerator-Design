//=====================================================================
// psum_accum_masked.sv -- partial-sum accumulator on TWO additive shares
//
// Same control behaviour as psum_accum (tile_start / first_tile /
// last_tile, per-column address counter, DEPTH overflow flag), but every
// datapath register exists once per share and all arithmetic is modulo
// 2^SHARE_W:
//     sum_k = din_k + (first_tile ? 0 : mem_k[addr])        k = 0, 1
//     (acc0_r + acc1_r) mod 2^SHARE_W  ==  baseline acc_r
// The two lanes never meet inside this module: the recombination (if any)
// happens OUTSIDE, so no net here is a function of the true partial sum.
//
// Shares-of-zero for first_tile are (0, 0); a fresh weight load changes
// the array masks, so lane contents stay uniformly distributed across
// tiles (each is a sum of independent uniform shares).
//
// RANGE.  The modulus must hold the true accumulated value:
//     |true| <= ROWS * MAX_TILES * 16384   (INT8 x INT8 products)
// This is checked STATICALLY at elaboration (needed_bits() <= SHARE_W);
// a runtime range check would require unmasking and is deliberately absent.
//=====================================================================
module psum_accum_masked #(
    parameter N         = 8,
    parameter SHARE_W   = 32,
    parameter COLS      = 5,
    parameter DEPTH     = 32,
    parameter AW        = 6,
    parameter ROWS      = 5,          // array rows summed into one column psum
    parameter MAX_TILES = 64          // max tiles accumulated into one address
)(
    input  wire                      clk,
    input  wire                      reset_n,
    input  wire                      tile_start,
    input  wire                      first_tile,
    input  wire                      last_tile,

    input  wire [COLS-1:0]           valid_in,
    input  wire [COLS*SHARE_W-1:0]   psum0_in,
    input  wire [COLS*SHARE_W-1:0]   psum1_in,
    output wire [COLS*SHARE_W-1:0]   psum0_out,
    output wire [COLS*SHARE_W-1:0]   psum1_out,
    output wire [COLS-1:0]           valid_out,
    output wire [COLS-1:0]           ovf
);
    // ---- static range check: signed bits needed for ROWS*MAX_TILES products ----
    function integer needed_bits(input integer rows, input integer tiles);
        integer worst, b;
        begin
            worst = rows * tiles * 16384;
            b = 1;
            while ((1 << (b - 1)) <= worst) b = b + 1;
            needed_bits = b;
        end
    endfunction

    initial begin
        if (needed_bits(ROWS, MAX_TILES) > SHARE_W) begin
            $display("psum_accum_masked ERROR: SHARE_W=%0d too small for ROWS=%0d x MAX_TILES=%0d (needs >= %0d bits)",
                     SHARE_W, ROWS, MAX_TILES, needed_bits(ROWS, MAX_TILES));
            $finish;
        end
    end

    genvar c;
    generate
        for (c = 0; c < COLS; c = c + 1) begin : g_lane
            reg [SHARE_W-1:0] mem0 [0:DEPTH-1];
            reg [SHARE_W-1:0] mem1 [0:DEPTH-1];
            reg [AW-1:0]      addr;
            reg [SHARE_W-1:0] acc0_r, acc1_r;
            reg               vld_r;
            reg               ovf_r;

            wire [SHARE_W-1:0] din0  = psum0_in[c*SHARE_W +: SHARE_W];
            wire [SHARE_W-1:0] din1  = psum1_in[c*SHARE_W +: SHARE_W];
            wire [SHARE_W-1:0] prev0 = first_tile ? {SHARE_W{1'b0}} : mem0[addr];
            wire [SHARE_W-1:0] prev1 = first_tile ? {SHARE_W{1'b0}} : mem1[addr];
            wire [SHARE_W-1:0] sum0  = din0 + prev0;
            wire [SHARE_W-1:0] sum1  = din1 + prev1;

            always @(posedge clk) begin
                if (!reset_n) begin
                    addr   <= {AW{1'b0}};
                    acc0_r <= {SHARE_W{1'b0}};
                    acc1_r <= {SHARE_W{1'b0}};
                    vld_r  <= 1'b0;
                    ovf_r  <= 1'b0;
                end else begin
                    if (tile_start) begin
                        addr  <= {AW{1'b0}};
                        ovf_r <= 1'b0;
                    end
                    vld_r <= valid_in[c] & last_tile;
                    if (valid_in[c]) begin
                        if (addr >= DEPTH) begin
                            ovf_r <= 1'b1;               // out of range: do not write, do not advance
                        end else begin
                            mem0[addr] <= sum0;
                            mem1[addr] <= sum1;
                            acc0_r     <= sum0;
                            acc1_r     <= sum1;
                            if (!tile_start) addr <= addr + 1;
                        end
                    end
                end
            end

            assign psum0_out[c*SHARE_W +: SHARE_W] = acc0_r;
            assign psum1_out[c*SHARE_W +: SHARE_W] = acc1_r;
            assign valid_out[c] = vld_r;
            assign ovf[c]       = ovf_r;
        end
    endgenerate
endmodule
