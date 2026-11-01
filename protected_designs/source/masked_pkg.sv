//=====================================================================
// masked_pkg.sv -- parameter/latency/randomness accounting for the
// Boolean-masked tail. Every module takes its random bits as ONE flat bus
// whose width and slice layout come from the functions below, so parent and
// child can never disagree about how many fresh bits a gadget consumes.
//=====================================================================
package masked_pkg;
    function automatic integer clog2i(input integer v);
        integer i;
        begin clog2i = 0; for (i = 1; i < v; i = i * 2) clog2i = clog2i + 1; end
    endfunction

    // ---------- masked Kogge-Stone adder, K bits ----------
    function automatic integer ks_layers(input integer K);
        ks_layers = clog2i(K);
    endfunction
    function automatic integer ks_wG(input integer K, input integer j);
        ks_wG = K - (1 << j);
    endfunction
    function automatic integer ks_wP(input integer K, input integer j);
        integer L;
        begin
            L = clog2i(K);
            ks_wP = (j < L - 1 && K - 2 * (1 << j) > 0) ? K - 2 * (1 << j) : 0;
        end
    endfunction
    function automatic integer ks_base(input integer K, input integer j);   // offset of layer j's slice
        integer m, t;
        begin t = K; for (m = 0; m < j; m = m + 1) t = t + ks_wG(K, m) + ks_wP(K, m); ks_base = t; end
    endfunction
    function automatic integer ks_rnd(input integer K);
        ks_rnd = ks_base(K, clog2i(K));
    endfunction
    function automatic integer ks_lat(input integer K);      // register stages input -> output
        ks_lat = 1 + clog2i(K);
    endfunction

    // ---------- comparator (a > b), N-bit signed ----------
    function automatic integer gt_rnd(input integer N);  gt_rnd = ks_rnd(N + 2); endfunction
    function automatic integer gt_lat(input integer N);  gt_lat = ks_lat(N + 2); endfunction

    // ---------- Goubin B2A ----------
    function automatic integer b2a_rnd(input integer K); b2a_rnd = K; endfunction
    localparam B2A_LAT = 5;

    // ---------- masked OR tree over n bits ----------
    function automatic integer or_lat(input integer n);  or_lat = clog2i(n); endfunction
    function automatic integer or_rnd(input integer n);  or_rnd = n - 1;     endfunction
    function automatic integer or_w(input integer n, input integer l);       // width after l levels
        integer w, i;
        begin w = n; for (i = 0; i < l; i = i + 1) w = (w + 1) / 2; or_w = w; end
    endfunction
    function automatic integer or_off(input integer n, input integer l);     // rnd offset of level l
        integer i, t;
        begin t = 0; for (i = 0; i < l; i = i + 1) t = t + or_w(n, i) / 2; or_off = t; end
    endfunction

    // ---------- requantize ----------
    function automatic integer rq_off_ks1(input integer a, input integer pw, input integer n);  rq_off_ks1 = 0; endfunction
    function automatic integer rq_rnd(input integer ACCW, input integer PW, input integer N);
        rq_rnd = ks_rnd(ACCW) + b2a_rnd(PW) + ks_rnd(PW) + or_rnd(PW - N) + (N - 1);
    endfunction
    function automatic integer rq_lat(input integer ACCW, input integer PW, input integer N);
        // S0 + A2B + B2A + mult/round reg + A2B + shift reg + OR tree + mux AND + out reg
        rq_lat = 1 + ks_lat(ACCW) + B2A_LAT + 1 + ks_lat(PW) + 1 + or_lat(PW - N) + 1 + 1;
    endfunction

    // ---------- activation ----------
    function automatic integer act_rnd(input integer N);  act_rnd = gt_rnd(N) + 4 * N; endfunction
    function automatic integer act_lat(input integer N);  act_lat = gt_lat(N) + 3;     endfunction

    // ---------- maxpool ----------
    function automatic integer mp_node_rnd(input integer N); mp_node_rnd = gt_rnd(N) + N; endfunction
    function automatic integer mp_leaves(input integer CW);  mp_leaves = 1 << CW;         endfunction
    function automatic integer mp_rnd(input integer N, input integer CW);
        mp_rnd = (mp_leaves(CW) - 1) * mp_node_rnd(N);
    endfunction
    function automatic integer mp_lat(input integer N, input integer CW);
        mp_lat = CW * (gt_lat(N) + 1) + 1;
    endfunction
endpackage
