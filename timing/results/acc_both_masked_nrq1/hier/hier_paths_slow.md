### Top 20 setup paths: acc_both_masked_nrq1 (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -10.334 | 19.912 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[145]_reg` | 2 |
| 2 | -10.177 | 19.787 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[22]_reg` | 2 |
| 3 | -10.177 | 19.787 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[274]_reg` | 2 |
| 4 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[476]_reg` | 2 |
| 5 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[478]_reg` | 2 |
| 6 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[479]_reg` | 2 |
| 7 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[480]_reg` | 2 |
| 8 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[481]_reg` | 2 |
| 9 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[483]_reg` | 2 |
| 10 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[486]_reg` | 2 |
| 11 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[488]_reg` | 2 |
| 12 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[489]_reg` | 2 |
| 13 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[498]_reg` | 2 |
| 14 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[502]_reg` | 2 |
| 15 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[504]_reg` | 2 |
| 16 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[508]_reg` | 2 |
| 17 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[509]_reg` | 2 |
| 18 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[100]_reg` | 2 |
| 19 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[101]_reg` | 2 |
| 20 | -10.034 | 19.048 | `u_rqs` | `g_core[0].rr[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[104]_reg` | 2 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `u_rqs` | `u_rqs/g_core[*].u_rng` | 20 | -10.334 |

#### All 4597 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `u_rqs/g_core[*].u_rng` | 512 | -10.334 | -3860.3 | `u_rqs` |
| `u_rqs` | 807 | -6.543 | -2444.2 | `top` |
| `u_bscale` | 417 | -5.104 | -1209.2 | `top` |
| `u_rqs/g_core[*].u_core/u_k0` | 16 | -4.240 | -33.8 | `u_rqs/g_core[*].u_core` |
| `u_load_ctrl` | 95 | -3.612 | -232.9 | `top` |
| `u_psum_accum` | 970 | -3.184 | -1679.5 | `top` |
| `u_ag` | 36 | -2.976 | -82.1 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 1175 | -2.930 | -2641.8 | `top` |
| `g_post[*].u_pool` | 100 | -2.841 | -165.2 | `top` |
| `u_array/u_mgen` | 159 | -2.767 | -108.1 | `top` |
| `u_array/g_shadow[*].sh_inst` | 95 | -2.742 | -246.7 | `top` |
| `top` | 30 | -2.682 | -41.8 | `top` |
| `u_array` | 89 | -2.608 | -24.6 | `top` |
| `g_post[*].u_act` | 45 | -2.595 | -104.4 | `top` |
| `u_rqs/g_core[*].u_core/u_rm` | 11 | -1.565 | -10.5 | `u_rqs/g_core[*].u_core/u_b2a` |
| `u_rqs/g_core[*].u_core` | 22 | -1.539 | -16.2 | `u_rqs/g_core[*].u_core` |
| `u_rqs/g_core[*].u_core/u_v` | 18 | -0.310 | -3.6 | `top` |
