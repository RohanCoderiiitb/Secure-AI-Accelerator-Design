//=====================================================================
// goubin_b2a.sv -- first-order Boolean -> arithmetic conversion (Goubin 2001)
//   in : Boolean shares (xp, r)   x = xp ^ r
//   out: arithmetic shares (A, rout)   x = A + rout  (mod 2^K)
//   T = xp ^ g;  T = T - g;  T = T ^ xp;  g' = g ^ r;
//   A = xp ^ g'; A = A - g'; A = A ^ T          (g = fresh random word)
// Every step is registered (latency B2A_LAT = 5) so no single net combines
// more than one step of the sequence; value-level first-order secure.
//=====================================================================
module goubin_b2a #(parameter K = 64) (
    input  wire         clk,
    input  wire [K-1:0] xp, r,
    input  wire [K-1:0] g,
    output wire [K-1:0] A, rout
);
    reg [K-1:0] T1, g1, xp1, r1;
    reg [K-1:0] T2, G2, xp2, r2;
    reg [K-1:0] T3, A1, G3, r3;
    reg [K-1:0] T4, A2, r4;
    reg [K-1:0] A3, r5;
    initial begin T1=0;g1=0;xp1=0;r1=0;T2=0;G2=0;xp2=0;r2=0;T3=0;A1=0;G3=0;r3=0;T4=0;A2=0;r4=0;A3=0;r5=0; end
    always @(posedge clk) begin
        T1  <= xp ^ g;       g1  <= g;       xp1 <= xp;       r1 <= r;
        T2  <= T1 - g1;      G2  <= g1 ^ r1; xp2 <= xp1;      r2 <= r1;
        T3  <= T2 ^ xp2;     A1  <= xp2 ^ G2; G3 <= G2;       r3 <= r2;
        T4  <= T3;           A2  <= A1 - G3;  r4 <= r3;
        A3  <= A2 ^ T4;      r5  <= r4;
    end
    assign A    = A3;
    assign rout = r5;
endmodule
