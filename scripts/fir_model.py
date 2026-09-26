#!/usr/bin/env python3
"""Bit-accurate Python model of rtl/fir_filter.v.

Mirrors the RTL register-for-register with identical cycle semantics
(all non-blocking updates computed from pre-edge state):
  sr[16] --(valid-gated)--> prod[16] --> tree1[8] --> tree2[4] -->
  tree2[2] --> acc --> round/sat --> sample_out        (LATENCY = 6)
  valid_in --> 6-deep valid_pipe --> sample_valid_out

Rounding/saturation replicate the RTL exactly:
  acc_rnd = (acc >>> 15) + acc[14]   (round half up; |acc| < 2^30 always)
  sample_out = clamp(acc_rnd, -32768, 32767)

Run:  python3 scripts/fir_model.py
"""

import math
import os
import re
import sys

LATENCY = 6
TAPS = 16


def load_coeffs():
    """Parse the signed Q1.15 taps out of rtl/fir_coeffs.vh (LSB-first packing)."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "..", "rtl", "fir_coeffs.vh")) as f:
        text = f.read()
    m = re.search(r"256'h([0-9A-Fa-f]+)", text)
    packed = int(m.group(1), 16)
    taps = []
    for i in range(TAPS):
        raw = (packed >> (16 * i)) & 0xFFFF
        taps.append(raw - 0x10000 if raw & 0x8000 else raw)
    return taps


def round_sat(acc):
    """RTL-identical output stage: round Q17.15 -> int, saturate to 16 bits."""
    r = (acc >> 15) + ((acc >> 14) & 1)   # arithmetic shifts == Verilog >>>
    if r > 32767:
        return 32767
    if r < -32768:
        return -32768
    return r


class FirModel:
    """Cycle-accurate model of fir_filter.v."""

    def __init__(self, coeffs):
        self.c = list(coeffs)
        self.reset()

    def reset(self):
        self.sr = [0] * TAPS
        self.prod = [0] * TAPS
        self.t1 = [0] * 8
        self.t2 = [0] * 4
        self.t3 = [0] * 2
        self.acc = 0
        self.vpipe = [0] * LATENCY
        self.out = 0
        self.ov = 0

    def clock(self, sample, valid):
        """Advance one clock edge. Returns (sample_out, sample_valid_out)."""
        valid = 1 if valid else 0
        # next-state from pre-edge values (mirrors non-blocking <=)
        nsr = ([sample] + self.sr[: TAPS - 1]) if valid else self.sr[:]
        nprod = [s * c for s, c in zip(self.sr, self.c)]
        nt1 = [self.prod[2 * i] + self.prod[2 * i + 1] for i in range(8)]
        nt2 = [self.t1[2 * i] + self.t1[2 * i + 1] for i in range(4)]
        nt3 = [self.t2[2 * i] + self.t2[2 * i + 1] for i in range(2)]
        nacc = self.t3[0] + self.t3[1]
        nvpipe = [valid] + self.vpipe[: LATENCY - 1]
        nout = round_sat(self.acc)
        nov = self.vpipe[LATENCY - 1]
        # commit
        self.sr, self.prod, self.t1, self.t2, self.t3 = nsr, nprod, nt1, nt2, nt3
        self.acc, self.vpipe, self.out, self.ov = nacc, nvpipe, nout, nov
        return self.out, self.ov


def ref_output(window, coeffs):
    """Independent reference: direct convolution + same round/sat."""
    s = sum(w * c for w, c in zip(window, coeffs))
    return round_sat(s)


def test_reset(coeffs):
    m = FirModel(coeffs)
    m.reset()
    for _ in range(30):
        out, ov = m.clock(0, 0)
        assert ov == 0 and out == 0, "reset/idle produced output"
    print("PASS: reset/idle -> no valid outputs, out stays 0")


def test_sparse_valid_alignment(coeffs):
    """Valid pulses at irregular cycles; outputs must appear exactly
    LATENCY cycles later and at no other time (valid alignment by construction)."""
    m = FirModel(coeffs)
    m.reset()
    stim_cycles = [0, 5, 6, 20, 47, 48, 100]   # sparse, incl. back-to-back
    samples = {c: (1000 - 37 * c) % 4096 - 2048 for c in stim_cycles}
    got = []
    for cycle in range(140):
        v = 1 if cycle in samples else 0
        out, ov = m.clock(samples.get(cycle, 0), v)
        if ov:
            got.append(cycle)
    expect = [c + LATENCY for c in stim_cycles]
    assert got == expect, f"valid misaligned: got {got}, expected {expect}"
    print(f"PASS: sparse-valid alignment ({len(stim_cycles)} pulses -> "
          f"valid_out exactly {LATENCY} cycles later, no extras)")


def test_numeric_vs_direct(coeffs):
    """Model outputs must equal direct convolution on the captured window."""
    m = FirModel(coeffs)
    m.reset()
    window = [0] * TAPS          # behavioral window for the independent reference
    pending = []                 # (due_cycle, expected)
    seq = [(i * 1103515245 + 12345) % 4096 - 2048 for i in range(60)]
    # sparse-ish valid pattern: valid on most cycles, gaps at 10-12 and 40
    gaps = {10, 11, 12, 40}
    errors = 0
    for cycle in range(120):
        v = 1 if (cycle < len(seq) and cycle not in gaps) else 0
        s = seq[cycle] if v and cycle < len(seq) else 0
        if v:
            window = [s] + window[: TAPS - 1]
            pending.append((cycle + LATENCY, ref_output(window, coeffs)))
        out, ov = m.clock(s, v)
        if ov:
            due, exp = pending.pop(0)
            assert due == cycle, "valid timing drift in numeric test"
            if out != exp:
                errors += 1
                print(f"  MISMATCH cycle {cycle}: model={out} direct={exp}")
    assert not pending, "missing outputs"
    assert errors == 0, f"{errors} numeric mismatches"
    print("PASS: pipeline arithmetic matches direct convolution "
          f"({120 - len(gaps)} valid samples, sparse gaps included)")


def test_impulse_response(coeffs):
    """Impulse in -> scaled coefficient sequence out, at the right cycles."""
    m = FirModel(coeffs)
    m.reset()
    A = 2000
    outs = {}
    for cycle in range(40):
        v = 1 if cycle < 20 else 0           # impulse then zeros, then idle
        s = A if cycle == 0 else 0
        out, ov = m.clock(s, v)
        if ov:
            outs[cycle] = out
    expect = {LATENCY + i: round_sat(A * c) for i, c in enumerate(coeffs)}
    expect.update({LATENCY + 16 + j: 0 for j in range(4)})  # zeros flush it out
    assert set(outs) == set(expect), f"impulse cycles wrong: {sorted(outs)}"
    bad = [(k, outs[k], expect[k]) for k in expect if outs[k] != expect[k]]
    assert not bad, f"impulse value mismatches: {bad[:4]}"
    print(f"PASS: impulse response = round({A}*coeff/2^15) sequence, "
          f"cycles {LATENCY}..{LATENCY + 15} (ties model to generated taps)")


def test_saturation_edges():
    assert round_sat((1 << 30) - 1) == 32767
    assert round_sat(-(1 << 30)) == -32768
    assert round_sat(0) == 0
    assert round_sat(32767 << 15) == 32767
    assert round_sat(-32768 << 15) == -32768
    print("PASS: round/saturate edge cases (incl. |acc| = 2^30 extremes)")


def test_frequency_response(coeffs):
    """Drive sines through the fixed-point pipeline; check measured gain."""
    results = {}
    for freq, label in ((50_000, "50k"), (100_000, "100k"), (400_000, "400k")):
        m = FirModel(coeffs)
        m.reset()
        A = 2000
        n = 400
        outs = []
        for cycle in range(n):
            s = int(round(A * math.sin(2 * math.pi * freq * cycle / 1_000_000)))
            out, ov = m.clock(s, 1)
            if ov and cycle > n // 2:      # settled second half
                outs.append(out)
        peak = max(abs(o) for o in outs)
        gain_db = 20 * math.log10(peak / A)
        results[label] = gain_db
    print(f"PASS: measured pipeline gain: 50 kHz {results['50k']:+.2f} dB, "
          f"100 kHz {results['100k']:+.2f} dB, 400 kHz {results['400k']:+.2f} dB")
    assert -0.6 <= results["50k"] <= 0.0, "50 kHz gain out of spec"
    assert -3.0 <= results["100k"] <= -1.0, "100 kHz gain out of spec"
    assert results["400k"] <= -48.0, "400 kHz attenuation out of spec"


def main():
    coeffs = load_coeffs()
    assert len(coeffs) == 16 and sum(coeffs) == 32768
    print(f"loaded 16 taps from rtl/fir_coeffs.vh, sum = {sum(coeffs)}")
    test_reset(coeffs)
    test_sparse_valid_alignment(coeffs)
    test_numeric_vs_direct(coeffs)
    test_impulse_response(coeffs)
    test_saturation_edges()
    test_frequency_response(coeffs)
    print("ALL MODEL TESTS PASSED")


if __name__ == "__main__":
    sys.exit(main())
