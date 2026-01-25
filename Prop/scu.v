// scu.v
// A single Sparse Computing Unit: consumes an input activation and a nonzero weight,
// performs multiply-accumulate and outputs psum. This is a small building block
// used inside the SCA. Parameterized for number of lanes.

`timescale 1ns/1ps
module scu #(
    parameter DATA_W = 16,
    parameter ACC_W = 32
)(
    input wire clk,
    input wire rst_n,
    input wire valid_in,
    input wire signed [DATA_W-1:0] act_in,
    input wire signed [DATA_W-1:0] weight_in,
    output reg signed [ACC_W-1:0] psum_out,
    output reg valid_out
);

reg signed [ACC_W-1:0] acc;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc <= 0;
        psum_out <= 0;
        valid_out <= 0;
    end else begin
        if (valid_in) begin
            acc <= acc + (act_in * weight_in);
            psum_out <= acc + (act_in * weight_in);
            valid_out <= 1'b1;
        end else begin
            valid_out <= 1'b0;
        end
    end
end

endmodule
