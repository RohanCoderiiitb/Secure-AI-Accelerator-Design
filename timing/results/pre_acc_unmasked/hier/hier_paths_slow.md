### Top 20 setup paths: pre_acc_unmasked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -10.241 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[4]_reg` | 1 |
| 2 | -10.241 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[4]_reg` | 1 |
| 3 | -10.241 | 20.006 | `g_post[2].u_requant` | `sh_s2[0]_reg` | `g_post[2].u_requant` | `q_out[4]_reg` | 1 |
| 4 | -10.241 | 20.006 | `g_post[3].u_requant` | `sh_s2[0]_reg` | `g_post[3].u_requant` | `q_out[4]_reg` | 1 |
| 5 | -10.241 | 20.006 | `g_post[4].u_requant` | `sh_s2[0]_reg` | `g_post[4].u_requant` | `q_out[4]_reg` | 1 |
| 6 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[0]_reg` | 1 |
| 7 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[1]_reg` | 1 |
| 8 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[2]_reg` | 1 |
| 9 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[3]_reg` | 1 |
| 10 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[5]_reg` | 1 |
| 11 | -10.240 | 20.006 | `g_post[0].u_requant` | `sh_s2[0]_reg` | `g_post[0].u_requant` | `q_out[6]_reg` | 1 |
| 12 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[0]_reg` | 1 |
| 13 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[1]_reg` | 1 |
| 14 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[2]_reg` | 1 |
| 15 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[3]_reg` | 1 |
| 16 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[5]_reg` | 1 |
| 17 | -10.240 | 20.006 | `g_post[1].u_requant` | `sh_s2[0]_reg` | `g_post[1].u_requant` | `q_out[6]_reg` | 1 |
| 18 | -10.240 | 20.006 | `g_post[2].u_requant` | `sh_s2[0]_reg` | `g_post[2].u_requant` | `q_out[0]_reg` | 1 |
| 19 | -10.240 | 20.006 | `g_post[2].u_requant` | `sh_s2[0]_reg` | `g_post[2].u_requant` | `q_out[1]_reg` | 1 |
| 20 | -10.240 | 20.006 | `g_post[2].u_requant` | `sh_s2[0]_reg` | `g_post[2].u_requant` | `q_out[2]_reg` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `g_post[*].u_requant` | `g_post[*].u_requant` | 20 | -10.241 |

#### All 175 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_requant` | 175 | -10.241 | -904.7 | `g_post[*].u_requant` |
