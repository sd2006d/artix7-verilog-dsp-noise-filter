// -----------------------------------------------------------------------------
// async_fifo.v -- asynchronous FIFO for clock-domain crossing.
//
// Dual-clock FIFO with Gray-coded read/write pointers and 2-flop
// synchronizers. Used here to move ADC samples from the sample clock domain
// into the 100 MHz DSP clock domain that feeds fir_filter.
//
//   wr_clk / wr_rst_n : write (source) clock domain
//   rd_clk / rd_rst_n : read (destination) clock domain
//   DEPTH = 2^ADDR_WIDTH
//
// Full/empty generation is the standard Gray-pointer comparison:
//   empty: rd_gray == wr_gray_synced_to_rd
//   full :  wr_gray == {~rd_gray_sync[MSB:MSB-1], rd_gray_sync[MSB-2:0]}
//          (i.e. write pointer is one full lap ahead of the read pointer)
// Resets are asynchronous-assert, synchronous-deassert per domain.
// -----------------------------------------------------------------------------
module async_fifo #(
    parameter integer DATA_WIDTH = 12,
    parameter integer ADDR_WIDTH = 4              // depth = 2^ADDR_WIDTH
)(
    input  wire                  wr_clk,
    input  wire                  wr_rst_n,       // async assert, sync deassert
    input  wire                  rd_clk,
    input  wire                  rd_rst_n,       // async assert, sync deassert
    // write port
    input  wire                  wr_en,
    input  wire [DATA_WIDTH-1:0] wr_data,
    output wire                  full,
    // read port
    input  wire                  rd_en,
    output reg  [DATA_WIDTH-1:0] rd_data,
    output wire                  empty
);

    localparam integer DEPTH = (1 << ADDR_WIDTH);

    // -- Memory ---------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // -- Pointers: binary for addressing, Gray for crossing -------------------
    reg [ADDR_WIDTH:0] wr_bin,  rd_bin;    // extra MSB = wrap bit
    reg [ADDR_WIDTH:0] wr_gray, rd_gray;

    // -- Synchronizers (2 flops each) ------------------------------------------
    reg [ADDR_WIDTH:0] wr_gray_sync1, wr_gray_sync2;  // wr ptr -> rd domain
    reg [ADDR_WIDTH:0] rd_gray_sync1, rd_gray_sync2;  // rd ptr -> wr domain

    function [ADDR_WIDTH:0] bin2gray;
        input [ADDR_WIDTH:0] bin;
        begin
            bin2gray = bin ^ (bin >> 1);
        end
    endfunction

    // -- Write domain -----------------------------------------------------------
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin  <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray <= {(ADDR_WIDTH+1){1'b0}};
        end else if (wr_en && !full) begin
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
            wr_bin  <= wr_bin + 1'b1;
            wr_gray <= bin2gray(wr_bin + 1'b1);
        end
    end

    // read pointer -> write domain
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            rd_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    // full when the next write position would catch the synced read pointer
    // exactly one lap behind (top two Gray bits inverted, rest equal).
    assign full = (wr_gray == {~rd_gray_sync2[ADDR_WIDTH:ADDR_WIDTH-1],
                               rd_gray_sync2[ADDR_WIDTH-2:0]});

    // -- Read domain ------------------------------------------------------------
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin  <= {(ADDR_WIDTH+1){1'b0}};
            rd_gray <= {(ADDR_WIDTH+1){1'b0}};
            rd_data <= {DATA_WIDTH{1'b0}};
        end else if (rd_en && !empty) begin
            rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
            rd_bin  <= rd_bin + 1'b1;
            rd_gray <= bin2gray(rd_bin + 1'b1);
        end
    end

    // write pointer -> read domain
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            wr_gray_sync1 <= {(ADDR_WIDTH+1){1'b0}};
            wr_gray_sync2 <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

    // empty when the read pointer has caught up with the synced write pointer
    assign empty = (rd_gray == wr_gray_sync2);

endmodule
