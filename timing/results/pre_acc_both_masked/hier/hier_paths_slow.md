### Top 20 setup paths: pre_acc_both_masked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -11.505 | 21.358 | `top (port)` | `bias_flat[0]` | `g_post[0].u_requant/u_rm` | `q[211]_reg` | 2 |
| 2 | -11.505 | 21.358 | `top (port)` | `bias_flat[32]` | `g_post[1].u_requant/u_rm` | `q[211]_reg` | 2 |
| 3 | -11.505 | 21.358 | `top (port)` | `bias_flat[64]` | `g_post[2].u_requant/u_rm` | `q[211]_reg` | 2 |
| 4 | -11.505 | 21.358 | `top (port)` | `bias_flat[96]` | `g_post[3].u_requant/u_rm` | `q[211]_reg` | 2 |
| 5 | -11.505 | 21.358 | `top (port)` | `bias_flat[128]` | `g_post[4].u_requant/u_rm` | `q[211]_reg` | 2 |
| 6 | -11.450 | 21.303 | `top (port)` | `bias_flat[0]` | `g_post[0].u_requant/u_rm` | `q[210]_reg` | 2 |
| 7 | -11.450 | 21.303 | `top (port)` | `bias_flat[32]` | `g_post[1].u_requant/u_rm` | `q[210]_reg` | 2 |
| 8 | -11.450 | 21.303 | `top (port)` | `bias_flat[64]` | `g_post[2].u_requant/u_rm` | `q[210]_reg` | 2 |
| 9 | -11.450 | 21.303 | `top (port)` | `bias_flat[96]` | `g_post[3].u_requant/u_rm` | `q[210]_reg` | 2 |
| 10 | -11.450 | 21.303 | `top (port)` | `bias_flat[128]` | `g_post[4].u_requant/u_rm` | `q[210]_reg` | 2 |
| 11 | -11.164 | 21.017 | `top (port)` | `bias_flat[0]` | `g_post[0].u_requant/u_rm` | `q[209]_reg` | 2 |
| 12 | -11.164 | 21.017 | `top (port)` | `bias_flat[32]` | `g_post[1].u_requant/u_rm` | `q[209]_reg` | 2 |
| 13 | -11.164 | 21.017 | `top (port)` | `bias_flat[64]` | `g_post[2].u_requant/u_rm` | `q[209]_reg` | 2 |
| 14 | -11.164 | 21.017 | `top (port)` | `bias_flat[96]` | `g_post[3].u_requant/u_rm` | `q[209]_reg` | 2 |
| 15 | -11.164 | 21.017 | `top (port)` | `bias_flat[128]` | `g_post[4].u_requant/u_rm` | `q[209]_reg` | 2 |
| 16 | -10.901 | 20.754 | `top (port)` | `bias_flat[0]` | `g_post[0].u_requant/u_rm` | `q[208]_reg` | 2 |
| 17 | -10.901 | 20.754 | `top (port)` | `bias_flat[32]` | `g_post[1].u_requant/u_rm` | `q[208]_reg` | 2 |
| 18 | -10.901 | 20.754 | `top (port)` | `bias_flat[64]` | `g_post[2].u_requant/u_rm` | `q[208]_reg` | 2 |
| 19 | -10.901 | 20.754 | `top (port)` | `bias_flat[96]` | `g_post[3].u_requant/u_rm` | `q[208]_reg` | 2 |
| 20 | -10.901 | 20.754 | `top (port)` | `bias_flat[128]` | `g_post[4].u_requant/u_rm` | `q[208]_reg` | 2 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top (port)` | `g_post[*].u_requant/u_rm` | 20 | -11.505 |

#### All 6302 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_requant/u_rm` | 370 | -11.505 | -2064.1 | `top (port)` |
| `g_post[*].u_rng` | 3517 | -5.530 | -14112.4 | `top` |
| `g_post[*].u_requant/u_b2a` | 125 | -4.523 | -272.2 | `top (port)` |
| `u_load_ctrl` | 71 | -2.111 | -117.9 | `top (port)` |
| `u_ag` | 30 | -1.538 | -37.4 | `top (port)` |
| `u_array/g_row[*].g_col[*].pe_inst` | 950 | -1.505 | -1242.3 | `top (port)` |
| `g_post[*].u_pool` | 60 | -1.489 | -74.3 | `top (port)` |
| `u_psum_accum` | 964 | -1.409 | -351.2 | `top (port)` |
| `u_array` | 3 | -1.370 | -3.7 | `top (port)` |
| `top` | 54 | -1.366 | -65.2 | `top (port)` |
| `u_array/u_mgen` | 38 | -1.363 | -33.9 | `top (port)` |
| `u_array/g_shadow[*].sh_inst` | 95 | -1.354 | -111.5 | `g_act_spad[*].u_act_spad/u_mem` |
| `g_post[*].u_act` | 25 | -1.181 | -28.6 | `top (port)` |
