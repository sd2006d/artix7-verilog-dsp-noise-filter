# Artix-7 Verilog DSP Noise Filter

A real-time 16-tap low-pass FIR filter in Verilog, targeting the Xilinx Artix-7
XC7A35T at a 100 MHz DSP clock. Built for the MLH hackathon at Davidson College
(Feb 2026).

## What it does

12-bit signed samples stream in (e.g. from an ADC), get low-pass filtered by a
16-tap symmetric FIR in Q1.15 fixed point, and come out as 16-bit signed samples
6 clock cycles later. An async FIFO bridges the ADC sample clock domain into
the 100 MHz DSP domain.

## Filter specification

| Parameter | Value |
|---|---|
| Sample rate (design) | 1 MHz |
| Cutoff frequency | 140 kHz |
| Taps | 16, symmetric, Hamming-windowed sinc |
| Coefficient format | Q1.15, tap sum = 32768 (unity DC gain) |
| Input | 12-bit signed |
| Output | 16-bit signed, round-half-up, saturated |
| Pipeline | 16 products, 16->8->4->2->1 adder tree, 6-cycle latency |
| DSP clock | 100 MHz |

Verified frequency response (from `scripts/gen_coeffs.py`, quantized taps):

| Frequency | Response |
|---|---|
| 50 kHz | -0.23 dB |
| 100 kHz | -2.04 dB |
| 400 kHz | -54.17 dB |
| worst over [300 kHz, 500 kHz] | -54.12 dB |

## Architecture

```
adc_clk domain                    dsp_clk domain (100 MHz)
┌───────────┐    ┌────────────┐    ┌──────────────────────────────────┐
│ ADC       │    │ async_fifo │    │ fir_filter                       │
│ sample +  ├───>│ Gray-coded ├─┬─>│ tap shift reg (gated on valid)   │
│ valid     │    │ pointers,  │ │  │  -> 16 products (registered)     │
└───────────┘    │ 16 deep    │ │  │  -> adder tree 16-8-4-2-1        │
                 └────────────┘ │  │  -> round + saturate -> out      │
                                │  │  valid_pipe: valid out exactly  │
                                │  │  6 cycles after valid in        │
                                │  └──────────────────────────────────┘
                                │   ▲
                                └───┘ rd_en delayed 1 cycle to match
                                      FIFO read latency
```

The valid-alignment scheme is the key correctness detail and is documented in
`rtl/fir_filter.v`: the tap shift register is **gated** by `sample_valid_in`
(idle cycles never smear the window), while the product registers, every
adder-tree stage, and the valid pipeline advance **every** clock. A valid
output therefore always corresponds to the input captured 6 cycles earlier,
by construction, even for sparse or bursty valid inputs.

## Repository layout

```
rtl/
  fir_filter.v       16-tap pipelined FIR, Q1.15
  fir_coeffs.vh      generated coefficients (do not edit; see scripts/)
  async_fifo.v       Gray-coded async FIFO for clock-domain crossing
  top_noise_filter.v top-level integration (FIFO + FIR, per-domain resets)
tb/
  tb_fir.v           self-checking testbench, sparse-valid stimulus
scripts/
  gen_coeffs.py      coefficient design + verification; regenerates fir_coeffs.vh
  fir_model.py       bit-accurate Python model of the RTL + test suite
constraints/
  artix7.xdc         timing constraints (starting point, see below)
sim/
  run_iverilog.sh    compile + run the testbench with Icarus Verilog
```

## Verification status (read this)

**Done -- Python bit-accurate model (`scripts/fir_model.py`), all 6 tests pass:**

- reset/idle produces no valid outputs
- sparse-valid alignment: 7 irregularly spaced valid pulses -> `sample_valid_out`
  asserts exactly 6 cycles later each time, with no extra strobes
- pipeline arithmetic matches an independent direct-convolution reference over
  116 valid samples including gaps
- impulse response equals `round(2000*coeff/2^15)` tap sequence on cycles 6..21,
  tying the model to the generated coefficients
- rounding/saturation edge cases, including |accumulator| = 2^30 extremes
- end-to-end sine measurements through the fixed-point pipeline:
  -0.34 dB @ 50 kHz, -2.04 dB @ 100 kHz, -53.98 dB @ 400 kHz

**Not done:**

- **HDL simulation**: `tb/tb_fir.v` is written and self-checking, but it has not
  been run here -- no Verilog simulator was available in this environment.
  Run it with `./sim/run_iverilog.sh` (Icarus Verilog) or in Vivado/ModelSim.
- **Synthesis / timing**: not run -- no Vivado here. Consequently this README
  makes **no** claims about timing closure, LUT/DSP/BRAM utilization, or Fmax.
  `constraints/artix7.xdc` is a starting point (clock definitions, async clock
  groups, max-delay constraints on the Gray-pointer and reset synchronizers);
  pin assignments must be adapted to your board.

## Regenerating the coefficients

```bash
python3 scripts/gen_coeffs.py   # verifies spec, rewrites rtl/fir_coeffs.vh
```

The script grid-searches the cutoff so that a plain Hamming-windowed sinc meets
the stopband target with only 16 taps; it fails loudly if the spec is not met.

## License

MIT -- see [LICENSE](LICENSE).
