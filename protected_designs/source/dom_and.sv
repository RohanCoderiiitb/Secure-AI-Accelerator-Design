//=====================================================================
// dom_and.sv -- first-order DOM-indep AND gadget, W parallel gates
//   z = (x0^x1) & (y0^y1) shared as (z0, z1), one fresh random bit per gate.
// All four product terms are REGISTERED (cross terms after the fresh-mask
// XOR, in-domain terms for alignment), the shares only meet after the
// registers in z = reg ^ reg of the SAME domain. Latency: 1 cycle.
// Reference: Gross, Mangard, Korak "Domain-Oriented Masking"; PINI
// composability of DOM-indep: Cassiers & Standaert.
// (Security is taken from the literature here; it is evaluated empirically
//  in Phase 6, and only in zero-delay RTL.)
//=====================================================================
module dom_and #(parameter W = 1) (
    input  wire         clk,
    input  wire [W-1:0] x0, x1, y0, y1,
    input  wire [W-1:0] r,
    output wire [W-1:0] z0, z1
);
    reg [W-1:0] p00, p11, t01, t10;
    initial begin p00 = 0; p11 = 0; t01 = 0; t10 = 0; end   // simulation only
    always @(posedge clk) begin
        p00 <= x0 & y0;
        p11 <= x1 & y1;
        t01 <= (x0 & y1) ^ r;
        t10 <= (x1 & y0) ^ r;
    end
    assign z0 = p00 ^ t01;
    assign z1 = p11 ^ t10;
endmodule
