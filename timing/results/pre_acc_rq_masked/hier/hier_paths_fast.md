### Top 20 setup paths: pre_acc_rq_masked (fast corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -1.301 | 11.227 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[22]_reg` | 1 |
| 2 | -1.301 | 11.227 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[337]_reg` | 1 |
| 3 | -1.301 | 11.227 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[595]_reg` | 1 |
| 4 | -1.294 | 11.220 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[657]_reg` | 1 |
| 5 | -1.294 | 11.220 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[661]_reg` | 1 |
| 6 | -1.291 | 11.258 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[148]_reg` | 1 |
| 7 | -1.291 | 11.258 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[17]_reg` | 1 |
| 8 | -1.291 | 11.258 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[19]_reg` | 1 |
| 9 | -1.291 | 11.258 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[468]_reg` | 1 |
| 10 | -1.291 | 11.258 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[470]_reg` | 1 |
| 11 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[147]_reg` | 1 |
| 12 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[276]_reg` | 1 |
| 13 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[339]_reg` | 1 |
| 14 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[341]_reg` | 1 |
| 15 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[529]_reg` | 1 |
| 16 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[531]_reg` | 1 |
| 17 | -1.287 | 11.254 | `top` | `g_post[1].rq_busy[0]_reg` | `g_post[1].u_rng` | `rnd[597]_reg` | 1 |
| 18 | -1.284 | 11.210 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[22]_reg` | 1 |
| 19 | -1.284 | 11.210 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[529]_reg` | 1 |
| 20 | -1.284 | 11.210 | `top` | `g_post[2].rq_busy[0]_reg` | `g_post[2].u_rng` | `rnd[595]_reg` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top` | `g_post[*].u_rng` | 20 | -1.301 |

#### All 1997 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_rng` | 1997 | -1.301 | -2084.6 | `top` |
