// -----------------------------------------------------------------------------
// tb_fir.v -- self-checking testbench for fir_filter.
//
// Strategy:
//   * A behavioral reference window (ref_sr) tracks exactly what the DUT's
//     tap shift register should hold.
//   * Each stimulus step computes the expected output with an independent
//     direct-convolution reference (ref_out function below).
//   * Expected (value, valid) pairs ride a 7-deep delay line; the pair
//     emerging at index 6 is compared against the DUT's sample_out /
//     sample_valid_out. This checks both the arithmetic AND the 6-cycle
//     valid alignment, under sparse (gappy) valid stimulus.
//   * Any mismatch (or an X) increments errors; the run ends with PASS/FAIL.
//
// Compile/run (Icarus Verilog):
//   iverilog -g2001 -I rtl -o sim/tb_fir.vvp tb/tb_fir.v rtl/fir_filter.v
//   vvp sim/tb_fir.vvp
// -----------------------------------------------------------------------------
`timescale 1ns/1ps

module tb_fir;

    `include "fir_coeffs.vh"   // FIR_COEFFS for the reference model

    reg               clk = 1'b0;
    reg               rst_n;
    reg signed [11:0] sample_in;
    reg               sample_valid_in;
    wire signed [15:0] sample_out;
    wire              sample_valid_out;

    fir_filter dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .sample_in        (sample_in),
        .sample_valid_in  (sample_valid_in),
        .sample_out       (sample_out),
        .sample_valid_out (sample_valid_out)
    );

    always #5 clk = ~clk;   // 100 MHz

    // -- Independent reference: direct convolution + RTL-identical round/sat --
    function signed [15:0] ref_out;
        integer k;
        reg signed [31:0] s;
        reg signed [17:0] se;
        reg signed [17:0] r;
        begin
            s = 32'sd0;
            for (k = 0; k < 16; k = k + 1)
                s = s + $signed(ref_sr[k]) * $signed(FIR_COEFFS[k*16 +: 16]);
            se = (s >>> 15);
            se = se[17:0];                       // exact sign extension (|s|<2^30)
            r  = se + {17'b0, s[14]};            // round half up
            if      (r >  18'sd32767) ref_out = 16'sd32767;
            else if (r < -18'sd32768) ref_out = -16'sd32768;
            else                     ref_out = r[15:0];
        end
    endfunction

    // -- Reference state ---------------------------------------------------------
    reg signed [11:0] ref_sr [0:15];
    reg signed [15:0] exp_q  [0:6];   // expected-output delay line
    reg               expv_q [0:6];   // expected-valid delay line

    integer s, k, errors, checks;
    reg signed [11:0] sin;
    reg vin;
    reg [31:0] lfsr;

    initial begin
        // init
        rst_n = 1'b0;
        sample_in = 12'sd0;
        sample_valid_in = 1'b0;
        errors = 0;
        checks = 0;
        lfsr = 32'h12345678;
        for (k = 0; k < 16; k = k + 1) ref_sr[k] = 12'sd0;
        for (k = 0; k < 7;  k = k + 1) begin exp_q[k] = 16'sd0; expv_q[k] = 1'b0; end

        repeat (5) @(posedge clk);
        #1 rst_n = 1'b1;   // DUT sees deassertion at the next posedge

        // --- stimulus steps ----------------------------------------------------
        // Inputs driven (NBA) just after each posedge are sampled by the DUT
        // at the NEXT posedge; the reference below models exactly that edge.
        for (s = 0; s < 260; s = s + 1) begin
            @(posedge clk);
            #1;

            // 1) compare the pair that is due now (computed 7 steps ago)
            if (s >= 7) begin
                if (expv_q[6] !== sample_valid_out) begin
                    $display("ERROR step %0d: valid_out=%b, expected %b",
                             s, sample_valid_out, expv_q[6]);
                    errors = errors + 1;
                end else if (sample_valid_out) begin
                    if (sample_out !== exp_q[6]) begin
                        $display("ERROR step %0d: out=%0d, expected %0d",
                                 s, sample_out, exp_q[6]);
                        errors = errors + 1;
                    end
                    checks = checks + 1;
                end
            end

            // 2) choose stimulus: impulse, sparse gaps, random bursts, drain
            vin = 1'b1;
            sin = 12'sd0;
            if (s < 10) begin
                vin = 1'b0;                              // initial idle
            end else if (s == 10) begin
                vin = 1'b1; sin = 12'sd2047;            // impulse
            end else if (s < 15) begin
                vin = 1'b0;                             // sparse gap
            end else if (s < 60) begin
                vin = 1'b1;                             // random burst
                lfsr = (lfsr * 1103515245 + 12345) & 32'h7fffffff;
                sin = $signed((lfsr % 4096) - 2048);
            end else if (s < 63) begin
                vin = 1'b0;                             // gap
            end else if (s < 140) begin
                vin = 1'b1;                             // random burst
                lfsr = (lfsr * 1103515245 + 12345) & 32'h7fffffff;
                sin = $signed((lfsr % 4096) - 2048);
            end else if (s < 150) begin
                vin = 1'b0;                             // long gap: pipe must flush
            end else if (s < 220) begin
                vin = 1'b1;
                lfsr = (lfsr * 1103515245 + 12345) & 32'h7fffffff;
                sin = $signed((lfsr % 4096) - 2048);
            end else begin
                vin = 1'b0;                             // final drain
            end
            sample_in       <= sin;
            sample_valid_in <= vin;

            // 3) reference update for the edge the DUT is about to sample
            if (vin) begin
                for (k = 15; k > 0; k = k - 1) ref_sr[k] = ref_sr[k-1];
                ref_sr[0] = sin;
            end
            for (k = 6; k > 0; k = k - 1) begin
                exp_q[k]  = exp_q[k-1];
                expv_q[k] = expv_q[k-1];
            end
            exp_q[0]  = ref_out();
            expv_q[0] = vin;
        end

        // --- report --------------------------------------------------------------
        #20;
        $display("--------------------------------------------------");
        $display("tb_fir: %0d value checks, %0d errors", checks, errors);
        if (errors == 0) $display("tb_fir: PASS");
        else             $display("tb_fir: FAIL");
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
