# The field tables for this core's ISSP probes, read by the MCP's read_issp.tcl and
# probe_sequence; moved from scripts/read_issp.tcl. Keep them in step with the probe
# bus the top-level .sv builds.
set fields_F {
    {frames           0  15 dec}
    {cpu_accesses    16  31 dec}
    {last_cpu_addr   32  55 hex}
    {rom_hits        56  71 dec}
    {rom_misses      72  87 dec}
    {tile_fetches    88 103 dec}
    {obj_fetches    104 119 dec}
    {pll_locked     120 120 bit}
    {rom_loaded     121 121 bit}
    {in_reset       122 122 bit}
    {unsupported    123 123 bit}
    {vblank         124 124 bit}
    {ioctl_download 125 125 bit}
    {esc_busy       126 126 bit}
    {cpu_on_esc     127 127 bit}
}

set fields_G {
    {ee_state         0   2 dec}
    {ee_locked        3   3 bit}
    {ee_sweep         4   9 dec}
    {ee_word0        16  31 hex}
    {ee_word1        32  47 hex}
    {ee_word63       48  63 hex}
}

set fields_H {
    {iack1            0  11 dec}
    {iack2           12  23 dec}
    {iack3           24  35 dec}
    {iack4           36  47 dec}
    {wrport1_1       48  55 hex}
    {ipl_n           56  58 dec}
    {int1            59  59 bit}
    {int2            60  60 bit}
    {irq3            61  61 bit}
    {irq4            62  62 bit}
    {iack            63  63 bit}
}

set fields_I {
    {esc_state        0   5 dec}
    {esc_addr_w       6  28 hex}
    {esc_set         29  52 hex}
    {esc_entry       53  61 dec}
    {esc_busy        62  62 bit}
    {esc_req         63  63 bit}
    {esc_done        64  71 dec}
    {cpu_sr          72  79 hex}
    {esc_count2      80  95 hex}
}

set fields_J {
    {dma_starts       0  11 dec}
    {vblanks         12  23 dec}
    {vbl_dmaen       24  35 dec}
    {dma_stale       36  47 dec}
    {dma_held        48  59 dec}
    {short_lines     64  75 dec}
    {short_last_frm  76  87 dec}
    {dma_during_esc  88  95 dec}
}

set fields_T {
    {frames           0  11 dec}
    {tm_late_total   12  23 dec}
    {tm_late_frm     24  35 dec}
    {tm_busy_max_frm 36  47 dec}
    {tm_busy_max     48  59 dec}
    {obj_busy_max_frm 60 71 dec}
    {obj_busy_max    72  83 dec}
    {tile_fetch_frm  84  99 dec}
    {tile_blank_frm 100 115 dec}
    {tile_skip_frm  116 131 dec}
    {ps_busy_max_frm 132 143 dec}
    {ps_busy_max    144 155 dec}
    {ps_late_frm    156 167 dec}
    {obj_late_frm   168 179 dec}
    {obj_late_total 180 191 dec}
    {ps_late_total  192 203 dec}
}

set fields_P {
    {clk32             0  15 dec}
    {map_fetches      16  33 dec}
    {crom_fetches     34  51 dec}
    {hrom_fetches     52  69 dec}
    {p1_map_stall     70  93 dec}
    {tex_stall        94 117 dec}
    {tex_fetch_busy  118 141 dec}
    {ovr_line        142 150 dec}
    {overruns        151 157 dec}
}

set fields_R {
    {t_snd_c0          0  15 dec}
    {t_snd_result     16  31 dec}
    {snd_result       32  39 hex}
    {t_main_rd0       40  55 dec}
    {t_main_rd1       56  71 dec}
    {main_rd1_value   72  79 hex}
    {t_cmd_first      80  95 dec}
    {t_cmd_last       96 111 dec}
    {n_cmd           112 119 dec}
    {cmd_last        120 127 hex}
    {now             128 143 dec}
}

set fields_B {
    {gfx_port_busy     0  23 dec}
    {snd_port_busy    24  47 dec}
    {tile_wait        48  71 dec}
    {obj_wait         72  95 dec}
    {psac_wait        96 119 dec}
    {snd_prog_req    120 143 dec}
    {dsp_ram_req     144 167 dec}
    {samples_req     168 191 dec}
    {snd_ram_req     192 215 dec}
    {snd_ram_write   216 239 dec}
    {cpu_port_busy2  240 263 dec}
}

set fields_K {
    {copy_cycles      0  25 dec}
    {download_cycles 26  51 dec}
    {byte_path       52  52 bit}
    {ddr3_copy       53  53 bit}
}

set fields_L {
    {vinmix           0  15 hex}
    {vmixon          16  31 hex}
    {input_enables   32  47 hex}
    {k338_alpha1     48  63 hex}
    {k338_alpha2     64  79 hex}
    {k338_control    80  95 hex}
    {scroll_modes    96 111 hex}
}

set fields_O {
    {data_lo          0  31 hex}
    {data_hi         32  63 hex}
    {rom_addr        64  86 hex}
    {code18          87 104 hex}
    {shmode         105 106 dec}
    {solid          107 107 bit}
    {partial        108 108 bit}
    {attr_full      109 124 hex}
    {objset1        125 132 hex}
    {captured       133 133 bit}
    {data_seen      134 134 bit}
}

set fields_S {
    {snd_addr          0  23 hex}
    {sctrl            24  31 hex}
    {in_reset         36  36 bit}
    {irq1             37  37 bit}
    {irq2             38  38 bit}
    {snd_accesses     39  54 dec}
    {int_pend         64  64 bit}
    {int_en           65  65 bit}
    {s2h1             66  73 hex}
    {s2h0             74  81 hex}
    {h2s3             82  89 hex}
    {h2s2             90  97 hex}
    {h2s1             98 105 hex}
    {h2s0            106 113 hex}
    {snd_run         114 114 bit}
    {snd_real        115 115 bit}
    {k539_1_late     116 131 dec}
    {k539_2_late     132 147 dec}
}

set fields_D {
    {pc                0   7 hex}
    {upd_head          8  11 dec}
    {upd_tail         12  15 dec}
    {x_req            16  16 bit}
    {x_wr             17  17 bit}
    {x_rd             18  18 bit}
    {host_full        19  19 bit}
    {idle             20  20 bit}
    {in_reset         21  21 bit}
    {cload            22  22 bit}
    {pload            23  23 bit}
    {state            24  25 dec}
    {longest_sample   26  37 dec}
    {overruns         38  49 dec}
    {samples          50  63 dec}
}

set fields_M {
    {gran_data_lo     0  31 hex}
    {gran_data_hi    32  63 hex}
    {gran_addr       64  83 hex}
}

set fields_N {
    {word0            0  15 hex}
    {word1           16  31 hex}
    {word2           32  47 hex}
    {word3           48  63 hex}
    {done            64  64 bit}
    {word_addr       65  87 hex}
}
