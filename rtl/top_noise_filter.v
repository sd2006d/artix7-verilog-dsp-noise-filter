// Top-Level FPGA Module: Real-Time Noise Filter Engine
// Target: Xilinx Artix-7 XC7A35T
// System Clock: 100.0 MHz

module top_noise_filter (
    input  wire        sys_clk,       // 100 MHz Core FPGA System Clock
    input  wire        sys_rst_n,     // Active Low Synchronous Reset
    input  wire        adc_clk,       // 50 MHz Async ADC Sampling Clock
    input  wire [11:0] adc_data_raw,  // 12-bit Unfiltered Sensor Sample
    output wire [15:0] filtered_data, // 16-bit Filtered Output Signal
    output wire        data_valid     // Output Data Valid Strobe
);

    wire [11:0] adc_data_sync;

    cdc_sync #(.DATA_WIDTH(12)) u_cdc_sync (
        .clk_dst(sys_clk),
        .rst_n(sys_rst_n),
        .async_in(adc_data_raw),
        .sync_out(adc_data_sync)
    );

    fir_filter u_fir_filter (
        .clk(sys_clk),
        .rst_n(sys_rst_n),
        .sample_in(adc_data_sync),
        .filtered_out(filtered_data),
        .out_valid(data_valid)
    );

endmodule
