// Constant functions shared by the masking gadgets, the masked requantizer and the tops

function integer mskf_m;                 // number of groups at tree level l
    input integer n, l;
    begin mskf_m = (n + (1 << l) - 1) >> l; end
endfunction

// carry-out reduction tree (n bits)
function integer mskf_cout_zoff;
    input integer n, lv;
    integer l;
    begin
        mskf_cout_zoff = n;
        for (l = 0; l < lv; l = l + 1) mskf_cout_zoff = mskf_cout_zoff + 2 * (mskf_m(n, l) / 2);
    end
endfunction
function integer mskf_cout_z;
    input integer n;
    begin mskf_cout_z = mskf_cout_zoff(n, $clog2(n)); end
endfunction

// AND reduction tree (n inputs)
function integer mskf_and_zoff;
    input integer n, lv;
    integer l;
    begin
        mskf_and_zoff = 0;
        for (l = 0; l < lv; l = l + 1) mskf_and_zoff = mskf_and_zoff + (mskf_m(n, l) / 2);
    end
endfunction
function integer mskf_and_z;
    input integer n;
    begin mskf_and_z = mskf_and_zoff(n, $clog2(n)); end
endfunction

// Sklansky prefix adder (n bits)
function integer mskf_skl_cnt;           // nodes at level j
    input integer n, j;
    integer i;
    begin
        mskf_skl_cnt = 0;
        for (i = 0; i < n; i = i + 1) if ((i >> j) & 1) mskf_skl_cnt = mskf_skl_cnt + 1;
    end
endfunction
function integer mskf_skl_zoff;
    input integer n, jv;
    integer j;
    begin
        mskf_skl_zoff = n;
        for (j = 0; j < jv; j = j + 1) mskf_skl_zoff = mskf_skl_zoff + 2 * mskf_skl_cnt(n, j);
    end
endfunction
function integer mskf_skl_z;
    input integer n;
    begin mskf_skl_z = mskf_skl_zoff(n, $clog2(n)); end
endfunction
function integer mskf_skl_rank;          // index of node i among level-j nodes
    input integer i, j;
    begin mskf_skl_rank = ((i >> (j + 1)) << j) + (i & ((1 << j) - 1)); end
endfunction

// prefix (carry) tree with G-only last level
function integer mskf_pfx_zoff;          // random bits of levels < jv (2 per node)
    input integer n, jv;
    integer j;
    begin
        mskf_pfx_zoff = 0;
        for (j = 0; j < jv; j = j + 1) mskf_pfx_zoff = mskf_pfx_zoff + 2 * mskf_skl_cnt(n, j);
    end
endfunction
function integer mskf_pfx_z;             // whole tree: last level needs G only (1 per node)
    input integer n;
    integer lv;
    begin
        lv = $clog2(n);
        if (lv == 0) mskf_pfx_z = 0;
        else         mskf_pfx_z = mskf_pfx_zoff(n, lv - 1) + mskf_skl_cnt(n, lv - 1);
    end
endfunction

// masked requantizer totals
function integer mskf_rq_rnd;            // random bits per cycle
    input integer xw, rw;
    begin
        mskf_rq_rnd = 2*xw + mskf_cout_z(xw)     // lift: input re-mask + carry tree
                    + 2*(rw - xw)                 // B2A of the carry (2 masks, upper bits)
                    + 2*rw                        // A2B input re-mask
                    + rw + mskf_pfx_z(rw)         // A2B: generate layer + prefix tree
                    + mskf_and_z(rw - 1)          // in-range (zero-detect) tree
                    + 1 + 8;                      // in-range AND + clamp ANDs
    end
endfunction
function integer mskf_rq_lat;            // input valid -> output valid, cycles
    input integer xw, rw, dreg;
    begin
        if (dreg) mskf_rq_lat = 1 + (1 + $clog2(xw)) + 2 + (1 + $clog2(rw)) + 1 + 1;
        else      mskf_rq_lat = 3;             // input, mid and output registers
    end
endfunction
