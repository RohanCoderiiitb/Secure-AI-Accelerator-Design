### Top 20 setup paths: acc_arr_masked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4049_` | 1 |
| 2 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4050_` | 1 |
| 3 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4051_` | 1 |
| 4 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4052_` | 1 |
| 5 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4053_` | 1 |
| 6 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4054_` | 1 |
| 7 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4055_` | 1 |
| 8 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4056_` | 1 |
| 9 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4057_` | 1 |
| 10 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4058_` | 1 |
| 11 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4059_` | 1 |
| 12 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4060_` | 1 |
| 13 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4061_` | 1 |
| 14 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4062_` | 1 |
| 15 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4063_` | 1 |
| 16 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4064_` | 1 |
| 17 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4065_` | 1 |
| 18 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4066_` | 1 |
| 19 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4067_` | 1 |
| 20 | -7.328 | 15.715 | `top` | `rst_n_reg` | `u_bscale` | `_4068_` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top` | `u_bscale` | 20 | -7.328 |

#### All 3460 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `u_bscale` | 451 | -7.328 | -1820.7 | `top` |
| `g_post[*].u_requant` | 690 | -6.352 | -2499.7 | `top` |
| `u_load_ctrl` | 95 | -4.770 | -337.9 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 1175 | -4.084 | -3950.6 | `top` |
| `u_psum_accum` | 495 | -4.081 | -1032.7 | `top` |
| `u_ag` | 36 | -4.046 | -124.3 | `top` |
| `g_post[*].u_pool` | 100 | -3.968 | -270.7 | `top` |
| `u_array` | 89 | -3.951 | -108.9 | `top` |
| `u_array/u_mgen` | 159 | -3.914 | -263.4 | `top` |
| `u_array/g_shadow[*].sh_inst` | 95 | -3.896 | -356.7 | `top` |
| `top` | 30 | -3.834 | -72.8 | `top` |
| `g_post[*].u_act` | 45 | -3.754 | -155.5 | `top` |
