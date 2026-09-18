# 48 MHz: the clk_sys this module will run on (docs/ROADMAP.md, clock plan).
create_clock -name clk -period 20.833 [get_ports clk]
derive_clock_uncertainty
