# Artix-7 Verilog DSP Noise Filter

Real-time 16-tap low-pass FIR filter in Verilog for the Xilinx Artix-7
XC7A35T, running at a 100 MHz DSP clock. Built for the MLH hackathon at
Davidson College (Feb 2026).

## What it does

12-bit signed samples stream in (e.g. from an ADC), get low-pass filtered
by a 16-tap symmetric FIR in Q1.15 fixed point, and come out as 16-bit
signed samples 6 clock cycles later. An async FIFO bridges the ADC sample
clock into the 100 MHz DSP domain.

## Filter spec

| Parameter | Value |
|---|---|
| Sample rate (design) | 1 MHz |
| Cutoff | 140 kHz |
| Taps | 16, symmetric, Hamming-windowed sinc |
| Coefficients | Q1.15, tap sum = 32768 (unity DC gain) |
| Input | 12-bit signed |
| Output | 16-bit signed, round-half-up, saturated |
| Pipeline | 16 products, 16->8->4->2->1 adder tree, 6-cycle latency |
| DSP clock | 100 MHz |

Frequency response of the quantized taps (from `scripts/gen_coeffs.py`):

| Frequency | Response |
|---|---|
| 50 kHz | -0.23 dB |
| 100 kHz | -2.04 dB |
| 400 kHz | -54.17 dB |
| worst, 300-500 kHz | -54.12 dB |

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

The tap shift register only shifts on `sample_valid_in`; everything
downstream (products, adder tree stages, valid pipeline) advances every
clock. So a valid output always lines up with the sample captured 6 cycles
earlier, even with sparse or bursty inputs. See `rtl/fir_filter.v` for the
details.

## Files

```
rtl/
  fir_filter.v       16-tap pipelined FIR, Q1.15
  fir_coeffs.vh      generated coefficients (do not edit; see scripts/)
  async_fifo.v       Gray-coded async FIFO for clock-domain crossing
  top_noise_filter.v top-level: FIFO + FIR, per-domain reset sync
tb/
  tb_fir.v           self-checking testbench, sparse-valid stimulus
scripts/
  gen_coeffs.py      coefficient design + spec check; rewrites fir_coeffs.vh
  fir_model.py       bit-accurate Python model of the RTL + test suite
constraints/
  artix7.xdc         timing constraints (starting point, see below)
sim/
  run_iverilog.sh    build + run the testbench with Icarus Verilog
```

## Testing

Python bit-accurate model (`scripts/fir_model.py`), 6/6 pass:

- idle/reset produces no valid outputs
- 7 irregularly spaced valid pulses -> `sample_valid_out` asserts exactly
  6 cycles after each one, no extras
- pipeline matches direct convolution over 116 valid samples with gaps
- impulse response equals the tap sequence on cycles 6-21
- rounding/saturation edges, including |accumulator| = 2^30
- sine through the fixed-point pipeline: -0.34 dB @ 50 kHz,
  -2.04 dB @ 100 kHz, -53.98 dB @ 400 kHz

Not tested yet:

- `tb/tb_fir.v` is written and self-checking but I haven't run it, no
  Verilog simulator available here. `./sim/run_iverilog.sh` (Icarus) or
  Vivado/ModelSim will do it.
- No synthesis run, so no timing or utilization numbers. The XDC is a
  starting point (clocks, async clock groups, max-delay on the Gray-pointer
  and reset synchronizers); pin assignments need your board.

## Coefficients

```bash
python3 scripts/gen_coeffs.py   # checks the spec, rewrites rtl/fir_coeffs.vh
```

Fails loudly if the taps don't meet spec. 16 taps wasn't enough at a 2 MHz
sample rate for the stopband I wanted (Kaiser says ~28), so the design
runs at 1 MHz where a plain Hamming-windowed sinc, fc = 140 kHz, meets
everything with margin.

## License

MIT, see [LICENSE](LICENSE).
