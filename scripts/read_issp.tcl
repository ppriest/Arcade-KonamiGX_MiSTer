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

set want ""
foreach a $argv { if {$a ne "clear"} { set want $a } }
set idx [lindex [lindex $insts 0] 0]
set inst_id [lindex [lindex $insts 0] 3]
if {$want ne ""} {
    foreach i $insts {
        if {[lindex $i 3] eq $want} { set idx [lindex $i 0]; set inst_id $want }
    }
}

switch -- $inst_id {
    F       { set fields $fields_F }
    G       { set fields $fields_G }
    H       { set fields $fields_H }
    I       { set fields $fields_I }
    J       { set fields $fields_J }
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
if {$do_clear} {
    write_src $idx 1
    write_src $idx 0
    puts "\ncounters cleared"
}

end_insystem_source_probe
