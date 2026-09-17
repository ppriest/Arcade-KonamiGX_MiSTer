# jotego's K053252 unit bench, from cores/rungun/ver/k053252/gather.f.
# It is DIFFERENTIAL: jtk053252.v (the implementation) is run against
# 053252.v (furrtek's silicon-derived reference) and the bench compares them.
sim/k053252_tb/test.v

# the implementation under test, vendored
rtl/video/k053252/jtk053252.v
rtl/video/k053252/jtk053252_mmr.v
rtl/jtframe/jtframe_edge.v
rtl/jtframe/jtframe_count_ld.v
rtl/jtframe/jtframe_ff_jk.v

# the golden reference it is checked against, and the TTL part it uses
sim/k053252_tb/053252.v
sim/k053252_tb/74163.v

# bench-only support from jtframe
sim/jtframe_ver/jtframe_frac_cen.v
sim/jtframe_ver/jtframe_vtimer.v
sim/jtframe_ver/jtframe_test_clocks.v
