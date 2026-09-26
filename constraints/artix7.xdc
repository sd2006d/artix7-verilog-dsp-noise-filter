# ---------------------------------------------------------------------------
# artix7.xdc -- timing constraints for top_noise_filter
# Device : xc7a35tcpg236-1 (Xilinx Artix-7). Adapt PACKAGE_PIN / IOSTANDARD
#          to your board; the pin mapping below is an EXAMPLE for a
#          Cmod A7-35T-style footprint and is NOT validated.
# Status : starting point only -- this project has not been through Vivado
#          synthesis/implementation, so treat every number below as a
#          first draft to be closed in the real flow.
# ---------------------------------------------------------------------------

# --- Clocks ----------------------------------------------------------------
# 100 MHz DSP clock driving the FIR pipeline
create_clock -period 10.000 -name dsp_clk [get_ports dsp_clk]

# 1 MHz sample clock (ADC domain). Adjust to your actual sample rate.
create_clock -period 1000.000 -name adc_clk [get_ports adc_clk]

# The two clock domains are asynchronous to each other by design
# (they meet only inside async_fifo's Gray-coded pointers).
set_clock_groups -asynchronous \
    -group [get_clocks dsp_clk] \
    -group [get_clocks adc_clk]

# --- Clock-domain crossings --------------------------------------------------
# Constrain the Gray-pointer synchronizer chains with a datapath-only max
# delay instead of a blanket false path, so the tools still verify they
# are met with margin. Two stages x 10 ns DSP period = 20 ns budget.
set_max_delay -datapath_only 20.0 \
    -from [get_cells -hierarchical -filter {NAME =~ *wr_gray_sync1_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *wr_gray_sync2_reg*}]
set_max_delay -datapath_only 20.0 \
    -from [get_cells -hierarchical -filter {NAME =~ *rd_gray_sync1_reg*}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *rd_gray_sync2_reg*}]

# Reset synchronizer chains: same treatment.
set_max_delay -datapath_only 20.0 \
    -from [get_cells -hierarchical -filter {NAME =~ *rst_sync_*_reg[0]}] \
    -to   [get_cells -hierarchical -filter {NAME =~ *rst_sync_*_reg[1]}]

# --- I/O (EXAMPLE -- replace with your board's pins) -------------------------
# set_property PACKAGE_PIN L17 [get_ports dsp_clk]   ;# 12 MHz on Cmod A7: use a PLL/MMCM for 100 MHz
# set_property IOSTANDARD LVCMOS33 [get_ports dsp_clk]
# set_property PACKAGE_PIN ... [get_ports adc_clk]
# set_property PACKAGE_PIN ... [get_ports rst_n]
# set_property PACKAGE_PIN ... [get_ports {adc_sample[*]}]
# set_property PACKAGE_PIN ... [get_ports adc_valid]
# set_property PACKAGE_PIN ... [get_ports {filtered_out[*]}]
# set_property PACKAGE_PIN ... [get_ports out_valid]
#
# set_input_delay  -clock [get_clocks adc_clk] -max 8.0 [get_ports {adc_sample[*] adc_valid}]
# set_output_delay -clock [get_clocks dsp_clk] -max 8.0 [get_ports {filtered_out[*] out_valid}]
