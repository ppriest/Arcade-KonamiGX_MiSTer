# This core's own read_issp commands, called after the decode in the same session.
# Register with core_register after every change.

# dump <first byte address> <words>: instance N's source asks gx_main to read
# four words at a time -- [0] toggles, [31:9] the word address -- and they
# come back on the same probe { addr [87:65], done [64], words [63:0] }. One
# line per group, for scripts/memdump.py. Read only RAM: a register read can
# clear what it reports.
proc hook_dump {idx first words} {
    scan $first %x dfirst
    set t 0
    set wa [expr {$dfirst >> 1}]
    set left $words
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
        puts [format "  dump %06X %04X %04X %04X %04X" [expr {$wa * 2}] \
              [bits_to_int $r 0 15] [bits_to_int $r 16 31] \
              [bits_to_int $r 32 47] [bits_to_int $r 48 63]]
        set wa [expr {$wa + 4}]
        set left [expr {$left - 4}]
    }
}

# peek <first granule> [count]: instance M's source asks the CPU's ROM cache
# to read a granule of the packed image -- [0] toggles, [31:12] the address --
# and the answer comes back on the same probe. The CPU is halted when this is
# used, so the fetch it reports is the peek's.
proc hook_peek {idx first {count 1}} {
    scan $first %x g0
    set t 0
    for {set g $g0} {$g < $g0 + $count} {incr g} {
        set t [expr {1 - $t}]
        write_src $idx [expr {($g << 12) | $t}]
        after 5
        set r [read_probe_data -instance_index $idx]
        set ga [bits_to_int $r 64 83]
        set lo [bits_to_int $r 0 31]
        set hi [bits_to_int $r 32 63]
        puts [format "  peek %05X -> %08X%08X%s" $ga $hi $lo \
              [expr {$ga == $g ? "" : [format "   (asked for %05X)" $g]}]]
    }
}

# src <hex>: set the instance's source bits and leave them
proc hook_src {idx value} {
    scan $value %x sv
    write_src $idx $sv
    puts [format "source set to %X" $sv]
}
