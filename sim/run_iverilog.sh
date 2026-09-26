#!/bin/bash
# Run the self-checking FIR testbench with Icarus Verilog.
# Usage: ./sim/run_iverilog.sh   (from the repo root)
set -e
cd "$(dirname "$0")/.."
iverilog -g2001 -I rtl -o sim/tb_fir.vvp tb/tb_fir.v rtl/fir_filter.v
vvp sim/tb_fir.vvp
