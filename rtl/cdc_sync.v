// 2-Stage DFF Clock Domain Crossing (CDC) Synchronizer
(* ASYNC_REG = "TRUE" *)
module cdc_sync #(
    parameter DATA_WIDTH = 12
)(
    input  wire                    clk_dst,
    input  wire                    rst_n,
    input  wire [DATA_WIDTH-1:0]  async_in,
    output reg  [DATA_WIDTH-1:0]  sync_out
);

    reg [DATA_WIDTH-1:0] stage1_reg;

    always @(posedge clk_dst or negedge rst_n) begin
        if (!rst_n) begin
            stage1_reg <= {DATA_WIDTH{1'b0}};
            sync_out   <= {DATA_WIDTH{1'b0}};
        end else begin
            stage1_reg <= async_in;
            sync_out   <= stage1_reg;
        end
    end

endmodule
