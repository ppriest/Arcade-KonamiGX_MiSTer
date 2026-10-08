# Read the core's debug probes over JTAG (In-System Sources and Probes).
#
#   python scripts/read_issp.py                  # read instance F (takes the hwlock)
#   python scripts/read_issp.py F clear          # read, then zero the counters
#
# From Arcade-Seta_MiSTer, with this core's field table. SignalTap acquisition
# is GUI-only in Quartus Prime Lite 17.0, so ISSP is what a headless workflow
# can drive. The probe bus layout is defined where the bus is BUILT
# (KonamiGX.sv, u_issp); keep the table below in step with it: a silently
# shifted field decodes as plausible nonsense rather than as an error.

# INSTANCE F, 128 bits, built in KonamiGX.sv under DEBUG_ISSP.
# The counters are not reset by the core's reset; `clear` (source bit 0)
# zeroes them, so clear then read again for a rate.
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

# INSTANCE G, 64 bits: the 93C46's state (rtl/gx_eeprom93c46.v dbg).
set fields_G {
    {ee_state         0   2 dec}
    {ee_locked        3   3 bit}
    {ee_sweep         4   9 dec}
    {ee_word0        16  31 hex}
    {ee_word1        32  47 hex}
    {ee_word63       48  63 hex}
}

# INSTANCE H, 64 bits: the interrupts (gx_main.sv dbg_irq). The ack
# counters free-run from reset: read twice for a rate. ipl_n is active low.
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

# INSTANCE I, 96 bits: the ESC (gx_main.sv dbg_esc_st). esc_addr is m_addr[23:1]:
# double it for the byte address.
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

# INSTANCE J, 64 bits: the sprite DMA (gx_main.sv dbg_obj). Counters
# free-run: read twice for a rate.
set fields_J {
    {dma_starts       0  11 dec}
    {vblanks         12  23 dec}
    {vbl_dmaen       24  35 dec}
    {objset1         40  47 hex}
    {objset1_vbl     48  55 hex}
    {objset1_dma     56  63 hex}
    {short_lines     64  75 dec}
    {short_last_frm  76  87 dec}
    {dma_during_esc  88  95 dec}
}

# INSTANCE T, 132 bits: line time (gx_video dbg_line). The *_frm fields are
# the last whole frame, latched at VBlank's start; busy counts are clocks of
# the 48 MHz clock (3072 a line) between one line start and the next.
# `src 1` turns gx_tilemap's blank-row skip off, `src 0` back on.
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
}

# INSTANCE K, 64 bits: the ROM load (KonamiGX.sv). The cycle counts are
# clk_sys (96 MHz): divide by 96,000 for milliseconds.
set fields_K {
    {copy_cycles      0  25 dec}
    {download_cycles 26  51 dec}
    {byte_path       52  52 bit}
    {ddr3_copy       53  53 bit}
}

# INSTANCE L, 96 bits: the mixer's registers (gx_video.sv dbg_mix).
set fields_L {
    {vinmix           0  15 hex}
    {vmixon          16  31 hex}
    {input_enables   32  47 hex}
    {k338_alpha1     48  63 hex}
    {k338_alpha2     64  79 hex}
    {k338_control    80  95 hex}
    {scroll_modes    96 111 hex}
}

# INSTANCE O, 136 bits: the first tile each frame of a sprite with shadow
# code 1 (gx_obj dbg_shd): what the scan decided, and the first granule the
# drawer was answered with for it
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

# INSTANCE M, 84 bits: the CPU ROM cache's last SDRAM fetch (gx_romcache).
# INSTANCE S, 116 bits: the sound board. snd_dbg [63:0] = { 9'd0,
# accesses, irq2, irq1, in reset, 4'd0, sctrl, address }, then the K056800's
# { h2s0-3, s2h0-1, int_en, int_pend } [113:64], snd_run [114], snd_real [115]
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

# INSTANCE D, 64 bits: gx_tms57002's dbg
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

# INSTANCE N, 88 bits: four words of CPU-visible memory (gx_main's JTAG
# reader). { addr, done, word 0..3 }.
set fields_N {
    {word0            0  15 hex}
    {word1           16  31 hex}
    {word2           32  47 hex}
    {word3           48  63 hex}
    {done            64  64 bit}
    {word_addr       65  87 hex}
}

proc bits_to_int {s lo hi} {
    # read_probe_data returns the bus MSB-first, so index from the right.
    set n [string length $s]
    set v 0
    for {set i $hi} {$i >= $lo} {incr i -1} {
        set c [string index $s [expr {$n - 1 - $i}]]
        set v [expr {$v * 2 + ($c eq "1" ? 1 : 0)}]
    }
    return $v
}

set do_clear [expr {[lsearch -exact $argv "clear"] >= 0}]

set hw ""
foreach h [get_hardware_names] { if {$hw eq ""} { set hw $h } }
if {$hw eq ""} { puts "NO JTAG HARDWARE FOUND"; exit 1 }
puts "hardware: $hw"

set dev ""
foreach d [get_device_names -hardware_name $hw] {
    if {[string match "*5CSEBA6*" $d] || [string match "*5CSE*" $d] || $dev eq ""} {
        set dev $d
    }
}
if {$dev eq ""} { puts "NO DEVICE FOUND"; exit 1 }
puts "device:   $dev"

# Query instance info BEFORE opening a session: with a session already active
# this fails with "There is already an active In-System Sources and Probes
# session started."
set insts [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
if {[llength $insts] == 0} {
    puts "NO ISSP INSTANCES -- is this an instrumented build?"
    exit 1
}
foreach i $insts { puts "instance: $i" }

# the instance is the first argument; "clear" and "peek ..." follow it
set want ""
if {[llength $argv] > 0} {
    set a0 [lindex $argv 0]
    if {$a0 ne "clear" && $a0 ne "peek" && $a0 ne "dump" && $a0 ne "src"} { set want $a0 }
}
set idx [lindex [lindex $insts 0] 0]
set inst_id [lindex [lindex $insts 0] 3]
if {$want ne ""} {
    # Refuse rather than fall back to instance 0: one DE10-nano is shared by
    # several cores, so the bitstream on the board may be another one's, and
    # decoding its probe against this core's field table reports numbers that
    # look real. That happened on 2026-09-20 -- instance I was read off a core
    # whose instances were M and V.
    set found 0
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0]; set inst_id $want; set found 1 }
    }
    if {!$found} {
        puts "INSTANCE '$want' IS NOT IN THE LOADED BITSTREAM -- it has: [join [lmap i $insts {lindex $i 3}] { }]"
        puts "is another core's build on the board? load this one and try again"
        exit 1
    }
}

switch -- $inst_id {
    F       { set fields $fields_F }
    G       { set fields $fields_G }
    H       { set fields $fields_H }
    I       { set fields $fields_I }
    J       { set fields $fields_J }
    K       { set fields $fields_K }
    O       { set fields $fields_O }
    L       { set fields $fields_L }
    M       { set fields $fields_M }
    N       { set fields $fields_N }
    S       { set fields $fields_S }
    D       { set fields $fields_D }
    T       { set fields $fields_T }
    default {
        puts "instance id '$inst_id' has no field table -- add one before reading it"
        exit 1
    }
}
puts "decoding instance $inst_id"

start_insystem_source_probe -device_name $dev -hardware_name $hw
set raw [read_probe_data -instance_index $idx]
puts "raw ([string length $raw] bits): $raw"
puts ""

foreach f $fields {
    lassign $f name lo hi fmt
    set v [bits_to_int $raw $lo $hi]
    switch $fmt {
        hex  { puts [format "  %-16s 0x%06X" $name $v] }
        bit  { puts [format "  %-16s %s"     $name [expr {$v ? "yes" : "no"}]] }
        default { puts [format "  %-16s %d"  $name $v] }
    }
}

# write_source_data takes a BINARY STRING unless -value_in_hex is given
proc write_src {idx v} { write_source_data -instance_index $idx -value [format %X $v] -value_in_hex }

# peek <first granule> [count]: instance M's source asks the CPU's ROM cache
# to read a granule of the packed image -- [0] toggles, [31:12] the address --
# and the answer comes back on the same probe. The CPU is halted when this is
# used, so the fetch it reports is the peek's.
# dump <first byte address> <words>: instance N's source asks gx_main to read
# four words at a time -- [0] toggles, [31:9] the word address -- and they
# come back on the same probe. One line per group, for scripts/memdump.py.
# Read only RAM: a register read can clear what it reports.
set dp [lsearch -exact $argv "dump"]
if {$dp >= 0} {
    scan [lindex $argv [expr {$dp + 1}]] %x dfirst
    set dwords [lindex $argv [expr {$dp + 2}]]
    set t 0
    set wa [expr {$dfirst >> 1}]
    set left $dwords
    while {$left > 0} {
        # A group is asked for by toggling, and the answer is believed only
        # when the probe reports that address. If it does not, the request is
        # made again rather than waited on: the toggle and the address cross
        # from this clock into the core's, and a build without the
        # synchroniser (gx_main, md_t2) can read the group before's address.
        set ok 0
        for {set issue 0} {$issue < 40 && !$ok} {incr issue} {
            set t [expr {1 - $t}]
            write_src $idx [expr {($wa << 9) | $t}]
            for {set tries 0} {$tries < 8} {incr tries} {
                set r [read_probe_data -instance_index $idx]
                # the reader leaves the address of the LAST word of the group
                if {[bits_to_int $r 64 64] && [bits_to_int $r 65 87] == $wa + 3} {
                    set ok 1
                    break
                }
                after 1
            }
        }
        if {!$ok} { puts "  dump stalled at [format %06X [expr {$wa*2}]]"; break }
        puts [format "  dump %06X %04X %04X %04X %04X" [expr {$wa * 2}]               [bits_to_int $r 0 15] [bits_to_int $r 16 31]               [bits_to_int $r 32 47] [bits_to_int $r 48 63]]
        set wa [expr {$wa + 4}]
        set left [expr {$left - 4}]
    }
}

set pk [lsearch -exact $argv "peek"]
if {$pk >= 0} {
    scan [lindex $argv [expr {$pk + 1}]] %x first
    set count 1
    if {[llength $argv] > $pk + 2} { set count [lindex $argv [expr {$pk + 2}]] }
    set t 0
    for {set g $first} {$g < $first + $count} {incr g} {
        set t [expr {1 - $t}]
        write_src $idx [expr {($g << 12) | $t}]
        after 5
        set r [read_probe_data -instance_index $idx]
        set ga [bits_to_int $r 64 83]
        set lo [bits_to_int $r 0 31]
        set hi [bits_to_int $r 32 63]
        puts [format "  peek %05X -> %08X%08X%s" $ga $hi $lo               [expr {$ga == $g ? "" : [format "   (asked for %05X)" $g]}]]
    }
}
# src <hex>: set the instance's source bits
set sp [lsearch -exact $argv "src"]
if {$sp >= 0} {
    scan [lindex $argv [expr {$sp + 1}]] %x sv
    write_src $idx $sv
    puts [format "
source set to %X" $sv]
}
if {$do_clear} {
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
