### Top 20 setup paths: acc_rq_masked_nrq5 (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -30.520 | 38.883 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[22]_reg` | 2 |
| 2 | -30.520 | 38.883 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[274]_reg` | 2 |
| 3 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[478]_reg` | 2 |
| 4 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[479]_reg` | 2 |
| 5 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[480]_reg` | 2 |
| 6 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[481]_reg` | 2 |
| 7 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[483]_reg` | 2 |
| 8 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[486]_reg` | 2 |
| 9 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[488]_reg` | 2 |
| 10 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[489]_reg` | 2 |
| 11 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[498]_reg` | 2 |
| 12 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[502]_reg` | 2 |
| 13 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[504]_reg` | 2 |
| 14 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[508]_reg` | 2 |
| 15 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `all[509]_reg` | 2 |
| 16 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[100]_reg` | 2 |
| 17 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[101]_reg` | 2 |
| 18 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[104]_reg` | 2 |
| 19 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[107]_reg` | 2 |
| 20 | -30.450 | 38.814 | `u_rqs` | `g_core[0].busy[0]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[108]_reg` | 2 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `u_rqs` | `u_rqs/g_core[*].u_rng` | 20 | -30.520 |

#### All 5088 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `u_rqs/g_core[*].u_rng` | 2560 | -30.520 | -68683.4 | `u_rqs` |
| `u_rqs` | 155 | -25.103 | -1572.4 | `u_rqs` |
| `u_bscale` | 451 | -15.268 | -5216.2 | `top` |
| `u_load_ctrl` | 95 | -12.947 | -1051.9 | `top` |
| `u_ag` | 36 | -12.414 | -411.3 | `top` |
| `u_psum_accum` | 495 | -12.362 | -4828.7 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 900 | -12.206 | -9802.2 | `top` |
| `g_post[*].u_pool` | 100 | -12.184 | -1025.5 | `top` |
| `g_post[*].u_act` | 45 | -12.047 | -520.8 | `top` |
| `top` | 21 | -12.039 | -206.4 | `top` |
| `u_array` | 10 | -8.043 | -78.6 | `top` |
| `u_rqs/g_core[*].u_core/u_v` | 90 | -8.043 | -706.7 | `top` |
| `u_rqs/g_core[*].u_core/u_k0` | 60 | -3.217 | -108.6 | `top` |
| `u_rqs/g_core[*].u_core/u_rm` | 70 | -2.483 | -79.6 | `u_rqs/g_core[*].u_core/u_b2a` |
