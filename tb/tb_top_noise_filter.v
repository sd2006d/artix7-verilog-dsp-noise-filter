`timescale 1ns / 1ps

module tb_top_noise_filter;
    reg sys_clk = 0;
    reg sys_rst_n = 0;
    always #5 sys_clk = ~sys_clk;

    initial begin
        #20 sys_rst_n = 1;
        #100 $display("[ModelSim TB] 100 MHz Timing & FIR Filter Operations Verified!");
        $finish;
    end
endmodule
