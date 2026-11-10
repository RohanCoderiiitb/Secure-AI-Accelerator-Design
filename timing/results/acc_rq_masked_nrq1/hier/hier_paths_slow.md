### Top 20 setup paths: acc_rq_masked_nrq1 (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -11.373 | 20.953 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[145]_reg` | 2 |
| 2 | -11.200 | 20.828 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[22]_reg` | 2 |
| 3 | -11.200 | 20.828 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[274]_reg` | 2 |
| 4 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[478]_reg` | 2 |
| 5 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[479]_reg` | 2 |
| 6 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[480]_reg` | 2 |
| 7 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[481]_reg` | 2 |
| 8 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[483]_reg` | 2 |
| 9 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[486]_reg` | 2 |
| 10 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[488]_reg` | 2 |
| 11 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[489]_reg` | 2 |
| 12 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[498]_reg` | 2 |
| 13 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[502]_reg` | 2 |
| 14 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[504]_reg` | 2 |
| 15 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[508]_reg` | 2 |
| 16 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `all[509]_reg` | 2 |
| 17 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[100]_reg` | 2 |
| 18 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[101]_reg` | 2 |
| 19 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[104]_reg` | 2 |
| 20 | -10.991 | 20.090 | `u_rqs` | `g_buf[2].cnt[1]_reg` | `u_rqs/g_core[0].u_rng` | `rnd[107]_reg` | 2 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `u_rqs` | `u_rqs/g_core[*].u_rng` | 20 | -11.373 |

#### All 2356 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `u_rqs/g_core[*].u_rng` | 512 | -11.373 | -4376.8 | `u_rqs` |
| `u_rqs` | 409 | -6.206 | -149.5 | `u_rqs` |
| `u_bscale` | 417 | -5.138 | -981.6 | `u_bscale` |
| `u_rqs/g_core[*].u_core/u_k0` | 16 | -4.240 | -33.8 | `u_rqs/g_core[*].u_core` |
| `u_load_ctrl` | 73 | -2.400 | -139.9 | `top` |
| `g_post[*].u_pool` | 55 | -1.829 | -79.9 | `top` |
| `u_psum_accum` | 112 | -1.711 | -180.4 | `top` |
| `u_ag` | 29 | -1.592 | -42.1 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 650 | -1.590 | -926.7 | `top` |
| `u_rqs/g_core[*].u_core/u_rm` | 11 | -1.565 | -10.5 | `u_rqs/g_core[*].u_core/u_b2a` |
| `u_rqs/g_core[*].u_core` | 22 | -1.539 | -16.2 | `u_rqs/g_core[*].u_core` |
| `top` | 10 | -1.382 | -13.7 | `top` |
| `g_post[*].u_act` | 40 | -1.381 | -54.9 | `top` |
