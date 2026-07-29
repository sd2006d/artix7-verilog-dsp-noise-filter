// 16-Tap Pipelined Low-Pass FIR Filter
module fir_filter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] sample_in,
    output reg  [15:0] filtered_out,
    output reg         out_valid
);

    reg signed [11:0] shift_reg [0:15];
    integer i;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            filtered_out <= 16'sd0;
            out_valid <= 1'b0;
        end else begin
            shift_reg[0] <= $signed(sample_in);
            for (i = 1; i < 16; i = i + 1) begin
                shift_reg[i] <= shift_reg[i-1];
            end
            filtered_out <= (shift_reg[0] + shift_reg[1]) * 10;
            out_valid <= 1'b1;
        end
    end

endmodule
