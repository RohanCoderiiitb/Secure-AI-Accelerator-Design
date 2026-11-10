### Top 20 setup paths: acc_unmasked (slow corner)

| # | Slack (ns) | Arrival (ns) | Start block | Start signal | End block | End signal | Blocks crossed |
|---:|---:|---:|---|---|---|---|---|
| 1 | -5.965 | 15.817 | `top` | `shift_q[2]_reg` | `g_post[0].u_requant` | `kr[47]_reg` | 1 |
| 2 | -5.965 | 15.817 | `top` | `shift_q[8]_reg` | `g_post[1].u_requant` | `kr[47]_reg` | 1 |
| 3 | -5.965 | 15.817 | `top` | `shift_q[14]_reg` | `g_post[2].u_requant` | `kr[47]_reg` | 1 |
| 4 | -5.965 | 15.817 | `top` | `shift_q[20]_reg` | `g_post[3].u_requant` | `kr[47]_reg` | 1 |
| 5 | -5.965 | 15.817 | `top` | `shift_q[26]_reg` | `g_post[4].u_requant` | `kr[47]_reg` | 1 |
| 6 | -5.924 | 15.715 | `top` | `shift_q[2]_reg` | `g_post[0].u_requant` | `kr[48]_reg` | 1 |
| 7 | -5.924 | 15.715 | `top` | `shift_q[8]_reg` | `g_post[1].u_requant` | `kr[48]_reg` | 1 |
| 8 | -5.924 | 15.715 | `top` | `shift_q[14]_reg` | `g_post[2].u_requant` | `kr[48]_reg` | 1 |
| 9 | -5.924 | 15.715 | `top` | `shift_q[20]_reg` | `g_post[3].u_requant` | `kr[48]_reg` | 1 |
| 10 | -5.924 | 15.715 | `top` | `shift_q[26]_reg` | `g_post[4].u_requant` | `kr[48]_reg` | 1 |
| 11 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4049_` | 1 |
| 12 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4050_` | 1 |
| 13 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4051_` | 1 |
| 14 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4052_` | 1 |
| 15 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4053_` | 1 |
| 16 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4054_` | 1 |
| 17 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4055_` | 1 |
| 18 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4056_` | 1 |
| 19 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4057_` | 1 |
| 20 | -5.918 | 14.305 | `top` | `rst_n_reg` | `u_bscale` | `_4058_` | 1 |

| Start block (class) | End block (class) | Paths in top list | Worst slack (ns) |
|---|---|---:|---:|
| `top` | `g_post[*].u_requant` | 10 | -5.965 |
| `top` | `u_bscale` | 10 | -5.918 |

#### All 2484 failing endpoints, by end block

| End block (class) | Failing endpoints | Worst slack (ns) | TNS (ns) | Start block of the worst path |
|---|---:|---:|---:|---|
| `g_post[*].u_requant` | 665 | -5.965 | -1677.5 | `top` |
| `u_bscale` | 450 | -5.918 | -1262.0 | `top` |
| `u_load_ctrl` | 76 | -3.261 | -202.8 | `top` |
| `g_post[*].u_pool` | 65 | -2.617 | -127.8 | `top` |
| `u_psum_accum` | 495 | -2.582 | -631.5 | `top` |
| `u_ag` | 31 | -2.457 | -67.6 | `top` |
| `u_array/g_row[*].g_col[*].pe_inst` | 650 | -2.449 | -1485.8 | `top` |
| `g_post[*].u_act` | 40 | -2.244 | -89.4 | `top` |
| `top` | 11 | -2.242 | -22.3 | `top` |
| `u_array` | 1 | -0.022 | -0.0 | `top` |
