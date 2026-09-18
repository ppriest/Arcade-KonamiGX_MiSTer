# 48 MHz: the clk_sys these blocks run on.
create_clock -name clk -period 20.833 [get_ports clk]
derive_clock_uncertainty
