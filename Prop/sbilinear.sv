// sbilinear.sv
`timescale 1ns/1ps

module sbilinear #(
    parameter int DATA_W = 16,
    parameter int SHW = 6
)(
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,
    input  logic signed [DATA_W-1:0] v00,
    input  logic signed [DATA_W-1:0] v01,
    input  logic signed [DATA_W-1:0] v10,
    input  logic signed [DATA_W-1:0] v11,
    input  logic [SHW-1:0] s0,
    input  logic [SHW-1:0] s1,
    input  logic [SHW-1:0] s2,
    input  logic [SHW-1:0] s3,

    output logic signed [DATA_W-1:0] out,
    output logic valid_out
);
    // 1-cycle pipeline: shift and accumulate
    logic signed [DATA_W+SHW:0] sum;
    logic signed [DATA_W+SHW:0] sum_next;

    always_comb begin
        sum_next = ($signed(v00) >>> s0)
                 + ($signed(v01) >>> s1)
                 + ($signed(v10) >>> s2)
                 + ($signed(v11) >>> s3);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum <= '0;
            out <= '0;
            valid_out <= 1'b0;
        end else begin
            if (valid_in) begin
                sum <= sum_next;
                out <= sum_next[DATA_W-1:0];
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end
endmodule
