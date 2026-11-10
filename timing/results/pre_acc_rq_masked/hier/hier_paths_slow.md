### Top 20 setup paths: pre_acc_rq_masked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -43.727 | 53.308 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[403]_reg` | 1 |
| 2 | -43.727 | 53.308 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[465]_reg` | 1 |
| 3 | -43.727 | 53.308 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[660]_reg` | 1 |
| 4 | -43.659 | 53.241 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[145]_reg` | 1 |
| 5 | -43.659 | 53.241 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[403]_reg` | 1 |
| 6 | -43.659 | 53.241 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[660]_reg` | 1 |
| 7 | -43.634 | 53.436 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[148]_reg` | 1 |
| 8 | -43.634 | 53.436 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[17]_reg` | 1 |
| 9 | -43.634 | 53.436 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[19]_reg` | 1 |
| 10 | -43.634 | 53.436 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[468]_reg` | 1 |
| 11 | -43.634 | 53.436 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[470]_reg` | 1 |
| 12 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[147]_reg` | 1 |
| 13 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[276]_reg` | 1 |
| 14 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[339]_reg` | 1 |
| 15 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[341]_reg` | 1 |
| 16 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[529]_reg` | 1 |
| 17 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[531]_reg` | 1 |
| 18 | -43.623 | 53.426 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[597]_reg` | 1 |
| 19 | -43.566 | 53.368 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[148]_reg` | 1 |
| 20 | -43.566 | 53.368 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[19]_reg` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top` | `g_post[*].u_rng` | 20 | -43.727 |

#### All 6041 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_rng` | 3520 | -43.727 | -137784.8 | `top` |
| `top` | 51 | -37.034 | -449.6 | `top` |
| `g_post[*].u_requant/u_rm` | 370 | -11.505 | -2064.1 | `top (port)` |
| `g_post[*].u_requant/u_b2a` | 125 | -4.523 | -272.2 | `top (port)` |
| `u_load_ctrl` | 64 | -2.741 | -144.8 | `top (port)` |
| `u_array/g_row[*].g_col[*].pe_inst` | 970 | -2.600 | -1800.0 | `g_act_spad[*].u_act_spad/u_mem` |
| `u_psum_accum` | 820 | -2.315 | -1260.6 | `top (port)` |
| `u_ag` | 31 | -2.187 | -57.1 | `top (port)` |
| `g_post[*].u_pool` | 65 | -2.121 | -112.9 | `top (port)` |
| `g_post[*].u_act` | 25 | -1.833 | -44.8 | `top (port)` |
