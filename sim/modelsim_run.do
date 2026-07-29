vlib work
vlog ../rtl/cdc_sync.v
vlog ../rtl/fir_filter.v
vlog ../rtl/top_noise_filter.v
vlog ../tb/tb_top_noise_filter.v
vsim work.tb_top_noise_filter
run 1us
