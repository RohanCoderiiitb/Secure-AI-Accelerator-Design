### Top 20 setup paths: pre_acc_arr_masked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -13.924 | 23.589 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[1]_reg` | 1 |
| 2 | -13.924 | 23.589 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[1]_reg` | 1 |
| 3 | -13.924 | 23.589 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[1]_reg` | 1 |
| 4 | -13.924 | 23.589 | `g_post[3].u_requant` | `sh_s2[2]_reg` | `g_post[3].u_requant` | `q_out[1]_reg` | 1 |
| 5 | -13.924 | 23.589 | `g_post[4].u_requant` | `sh_s2[2]_reg` | `g_post[4].u_requant` | `q_out[1]_reg` | 1 |
| 6 | -13.753 | 23.496 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[0]_reg` | 1 |
| 7 | -13.753 | 23.496 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[2]_reg` | 1 |
| 8 | -13.753 | 23.496 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[3]_reg` | 1 |
| 9 | -13.753 | 23.496 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[4]_reg` | 1 |
| 10 | -13.753 | 23.496 | `g_post[0].u_requant` | `sh_s2[2]_reg` | `g_post[0].u_requant` | `q_out[5]_reg` | 1 |
| 11 | -13.753 | 23.496 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[0]_reg` | 1 |
| 12 | -13.753 | 23.496 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[2]_reg` | 1 |
| 13 | -13.753 | 23.496 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[3]_reg` | 1 |
| 14 | -13.753 | 23.496 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[4]_reg` | 1 |
| 15 | -13.753 | 23.496 | `g_post[1].u_requant` | `sh_s2[2]_reg` | `g_post[1].u_requant` | `q_out[5]_reg` | 1 |
| 16 | -13.753 | 23.496 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[0]_reg` | 1 |
| 17 | -13.753 | 23.496 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[2]_reg` | 1 |
| 18 | -13.753 | 23.496 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[3]_reg` | 1 |
| 19 | -13.753 | 23.496 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[4]_reg` | 1 |
| 20 | -13.753 | 23.496 | `g_post[2].u_requant` | `sh_s2[2]_reg` | `g_post[2].u_requant` | `q_out[5]_reg` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `g_post[*].u_requant` | `g_post[*].u_requant` | 20 | -13.924 |

#### All 364 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_requant` | 280 | -13.924 | -1780.2 | `g_post[*].u_requant` |
| `u_array/g_row[*].g_col[*].pe_inst` | 70 | -0.974 | -33.8 | `g_act_spad[*].u_act_spad/u_mem` |
| `u_array/g_shadow[*].sh_inst` | 14 | -0.974 | -7.8 | `g_act_spad[*].u_act_spad/u_mem` |
