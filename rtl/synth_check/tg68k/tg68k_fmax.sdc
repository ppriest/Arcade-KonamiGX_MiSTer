# Ask for more than the kernel can do, so the report shows the true limit as
# negative slack and the Fmax summary names the achievable frequency. 100 MHz
# is comfortably beyond the 48.74 MHz Psikyo measured in its full design.
create_clock -name clk -period 10.000 [get_ports clk]
derive_clock_uncertainty
