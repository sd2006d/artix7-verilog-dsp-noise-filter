// -----------------------------------------------------------------------------
// fir_filter.v -- 16-tap symmetric low-pass FIR filter, Q1.15 fixed point.
//
// Target: Xilinx Artix-7 XC7A35T, 100 MHz DSP clock.
//
// Data format:
//   sample_in   : signed 12-bit integer sample (e.g. from a 12-bit ADC)
//   coefficients: signed 16-bit Q1.15 (see rtl/fir_coeffs.vh)
//   product     : signed 28-bit (Q13.15)
//   accumulator : signed 32-bit (Q17.15); 16 products can never overflow it
//                 (max |product| = 2^26, 16 of them < 2^30 < 2^31)
//   sample_out  : signed 16-bit integer = round(acc / 2^15), saturated
//
// Pipeline (LATENCY = 6 cycles):
//   stage 0 : tap shift register  (16 deep)
//   stage 1 : 16 registered products
//   stage 2 : adder tree 16 -> 8
//   stage 3 : adder tree  8 -> 4
//   stage 4 : adder tree  4 -> 2
//   stage 5 : adder tree  2 -> 1 (final 32-bit accumulator)
//   stage 6 : output register with rounding + saturation
//
// Valid alignment: the tap shift register only shifts on sample_valid_in,
// everything downstream advances every clock, and the valid flag rides an
// identical shift register. So a valid output always corresponds to the
// sample from LATENCY cycles earlier, even with sparse/bursty inputs.
// -----------------------------------------------------------------------------
module fir_filter (
    input  wire               clk,
    input  wire               rst_n,            // asynchronous, active low
    input  wire signed [11:0] sample_in,        // 12-bit signed input sample
    input  wire               sample_valid_in,  // strobe: shift in sample_in
    output reg  signed [15:0] sample_out,       // 16-bit signed filtered output
    output reg                sample_valid_out  // strobe: sample_out is valid
);

    // Filter coefficients (signed Q1.15). FIR_COEFFS[16*i +: 16] = tap i.
    `include "fir_coeffs.vh"

    localparam integer TAPS    = 16;
    localparam integer LATENCY = 6;  // product + 4 tree stages + output reg

    // -- Stage 0: tap delay line. GATED by sample_valid_in (see header). -----
    reg signed [11:0] sr [0:TAPS-1];

    // -- Stages 1..5: products + pipelined adder tree. Advance EVERY cycle. --
    reg signed [27:0] prod  [0:15];  // stage 1: tap * coeff
    reg signed [28:0] tree1 [0:7];   // stage 2: 16 -> 8
    reg signed [29:0] tree2 [0:3];   // stage 3:  8 -> 4
    reg signed [30:0] tree3 [0:1];   // stage 4:  4 -> 2
    reg signed [31:0] acc;           // stage 5:  2 -> 1, Q17.15

    // -- Valid pipeline: identical shift register for the strobe. -------------
    reg [LATENCY-1:0] valid_pipe;

    integer i;

    // Stage 0: gated shift register.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < TAPS; i = i + 1)
                sr[i] <= 12'sd0;
        end else if (sample_valid_in) begin
            sr[0] <= sample_in;
            for (i = 1; i < TAPS; i = i + 1)
                sr[i] <= sr[i-1];
        end
    end

    // Stages 1-5: ungated pipeline. Non-blocking assignments sample the
    // pre-edge register values, so each stage sees the previous stage's
    // settled output exactly one cycle later.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 16; i = i + 1) prod[i]  <= 28'sd0;
            for (i = 0; i < 8;  i = i + 1) tree1[i] <= 29'sd0;
            for (i = 0; i < 4;  i = i + 1) tree2[i] <= 30'sd0;
            for (i = 0; i < 2;  i = i + 1) tree3[i] <= 31'sd0;
            acc <= 32'sd0;
        end else begin
            for (i = 0; i < 16; i = i + 1)
                prod[i] <= $signed(sr[i]) * $signed(FIR_COEFFS[i*16 +: 16]);
            for (i = 0; i < 8; i = i + 1)
                tree1[i] <= $signed(prod[2*i]) + $signed(prod[2*i+1]);
            for (i = 0; i < 4; i = i + 1)
                tree2[i] <= $signed(tree1[2*i]) + $signed(tree1[2*i+1]);
            for (i = 0; i < 2; i = i + 1)
                tree3[i] <= $signed(tree2[2*i]) + $signed(tree2[2*i+1]);
            acc <= $signed(tree3[0]) + $signed(tree3[1]);
        end
    end

    // Valid pipeline: advances every cycle, mirroring the data latency.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            valid_pipe <= {LATENCY{1'b0}};
        else
            valid_pipe <= {valid_pipe[LATENCY-2:0], sample_valid_in};
    end

    // Stage 6: round acc (Q17.15) to integer and saturate to 16 bits.
    // |acc| < 2^30 always, so acc>>>15 fits in 17 bits signed; the [17:0]
    // slice is an exact sign extension. Rounding is round-half-up via bit 14.
    wire signed [31:0] acc_shr  = acc >>> 15;
    wire signed [17:0] acc_sext = acc_shr[17:0];
    wire signed [17:0] rnd_bit  = {17'b0, acc[14]};
    wire signed [17:0] acc_rnd  = acc_sext + rnd_bit;
    wire signed [15:0] acc_sat  = (acc_rnd >  18'sd32767) ? 16'sd32767 :
                                 (acc_rnd < -18'sd32768) ? -16'sd32768 :
                                                           acc_rnd[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_out       <= 16'sd0;
            sample_valid_out <= 1'b0;
        end else begin
            sample_out       <= acc_sat;
            sample_valid_out <= valid_pipe[LATENCY-1];
        end
    end

endmodule
