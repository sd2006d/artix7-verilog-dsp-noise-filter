// -----------------------------------------------------------------------------
// top_noise_filter.v -- top-level integration: async FIFO + FIR noise filter.
//
//   adc_clk domain : 12-bit samples arrive with adc_valid, are written into
//                    the async FIFO.
//   dsp_clk domain : samples are drained from the FIFO into fir_filter;
//                    filtered_out / out_valid carry the result.
//
// Resets: rst_n is asynchronous-assert; each clock domain gets its own
// 2-flop synchronized deassertion (rst_sync_adc, rst_sync_dsp).
//
// NOTE: pin assignments and clock sources live in constraints/artix7.xdc and
// must be adapted to the actual board.
// -----------------------------------------------------------------------------
module top_noise_filter (
    input  wire        adc_clk,       // sample clock, e.g. 1 MHz
    input  wire        dsp_clk,       // DSP clock, 100 MHz
    input  wire        rst_n,         // async, active low (e.g. pushbutton)
    input  wire [11:0] adc_sample,   // 12-bit signed sample
    input  wire        adc_valid,     // strobe in adc_clk domain
    output wire [15:0] filtered_out, // 16-bit signed filtered sample
    output wire        out_valid      // strobe in dsp_clk domain
);

    // -- Reset synchronizers (async assert, sync deassert per domain) ----------
    reg [1:0] rst_sync_adc, rst_sync_dsp;
    wire adc_rst_n, dsp_rst_n;

    always @(posedge adc_clk or negedge rst_n) begin
        if (!rst_n) rst_sync_adc <= 2'b00;
        else        rst_sync_adc <= {rst_sync_adc[0], 1'b1};
    end
    always @(posedge dsp_clk or negedge rst_n) begin
        if (!rst_n) rst_sync_dsp <= 2'b00;
        else        rst_sync_dsp <= {rst_sync_dsp[0], 1'b1};
    end
    assign adc_rst_n = rst_sync_adc[1];
    assign dsp_rst_n = rst_sync_dsp[1];

    // -- ADC domain -> DSP domain FIFO ------------------------------------------
    wire [11:0] fifo_dout;
    wire        fifo_full, fifo_empty;
    wire        fifo_rd_en  = ~fifo_empty;   // drain whenever data is present
    reg         fifo_rd_en_d;                // aligns valid with FIFO read latency

    async_fifo #(
        .DATA_WIDTH(12),
        .ADDR_WIDTH(4)                      // 16-deep
    ) u_cdc_fifo (
        .wr_clk   (adc_clk),
        .wr_rst_n (adc_rst_n),
        .rd_clk   (dsp_clk),
        .rd_rst_n (dsp_rst_n),
        .wr_en    (adc_valid & ~fifo_full),
        .wr_data  (adc_sample),
        .full     (fifo_full),
        .rd_en    (fifo_rd_en),
        .rd_data  (fifo_dout),
        .empty    (fifo_empty)
    );

    // Standard (non-FWFT) read: dout updates the cycle after rd_en, so delay
    // the FIR's valid strobe by one dsp_clk to match.
    always @(posedge dsp_clk or negedge dsp_rst_n) begin
        if (!dsp_rst_n) fifo_rd_en_d <= 1'b0;
        else            fifo_rd_en_d <= fifo_rd_en;
    end

    // -- DSP domain: 16-tap FIR ---------------------------------------------------
    fir_filter u_fir (
        .clk              (dsp_clk),
        .rst_n            (dsp_rst_n),
        .sample_in        (fifo_dout),
        .sample_valid_in  (fifo_rd_en_d),
        .sample_out       (filtered_out),
        .sample_valid_out (out_valid)
    );

endmodule
