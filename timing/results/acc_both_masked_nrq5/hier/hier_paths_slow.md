### Top 20 setup paths: acc_both_masked_nrq5 (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4063_` | 1 |
| 2 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4064_` | 1 |
| 3 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4065_` | 1 |
| 4 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4066_` | 1 |
| 5 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4067_` | 1 |
| 6 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4068_` | 1 |
| 7 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4069_` | 1 |
| 8 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4070_` | 1 |
| 9 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4071_` | 1 |
| 10 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4072_` | 1 |
| 11 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4073_` | 1 |
| 12 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4074_` | 1 |
| 13 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4075_` | 1 |
| 14 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4076_` | 1 |
| 15 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4077_` | 1 |
| 16 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4078_` | 1 |
| 17 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4079_` | 1 |
| 18 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4080_` | 1 |
| 19 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4081_` | 1 |
| 20 | -16.776 | 25.158 | `top` | `rst_n_reg` | `u_bscale` | `_4082_` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top` | `u_bscale` | 20 | -16.776 |

#### All 6275 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `u_bscale` | 451 | -16.776 | -5874.0 | `top` |
| `u_rqs/g_core[*].u_rng` | 2560 | -15.809 | -37117.1 | `top` |
| `u_load_ctrl` | 95 | -14.554 | -1195.4 | `top` |
| `u_psum_accum` | 970 | -14.213 | -10336.9 | `top` |
| `u_ag` | 36 | -14.022 | -467.3 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 1175 | -13.938 | -15128.0 | `top` |
| `g_post[*].u_pool` | 100 | -13.797 | -1171.9 | `top` |
| `u_array/g_shadow[*].sh_inst` | 95 | -13.751 | -1295.2 | `top` |
| `u_rqs` | 250 | -13.737 | -2600.0 | `top` |
| `top` | 30 | -13.723 | -336.4 | `top` |
| `u_array/u_mgen` | 159 | -13.702 | -1596.1 | `top` |
| `g_post[*].u_act` | 45 | -13.655 | -591.6 | `top` |
| `u_array` | 89 | -13.649 | -827.3 | `top` |
| `u_rqs/g_core[*].u_core/u_v` | 90 | -9.358 | -823.9 | `top` |
| `u_rqs/g_core[*].u_core/u_k0` | 60 | -3.217 | -108.6 | `top` |
| `u_rqs/g_core[*].u_core/u_rm` | 70 | -2.483 | -79.6 | `u_rqs/g_core[*].u_core/u_b2a` |
