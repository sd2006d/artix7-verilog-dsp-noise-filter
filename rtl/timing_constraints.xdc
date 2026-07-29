## Xilinx Artix-7 Constraints
create_clock -period 10.000 -name sys_clk_pin [get_ports sys_clk]
create_clock -period 20.000 -name adc_clk_pin [get_ports adc_clk]
set_max_delay -from [get_clocks adc_clk_pin] -to [get_clocks sys_clk_pin] 8.000 -datapath_only
