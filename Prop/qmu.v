// qmu.v
// Simple Quality Modulating Unit: scales input feature depending on mode.
// Real IQML/IQML uses learned parameters; here we provide parameterizable scaling.

`timescale 1ns/1ps
module qmu #(
    parameter DATA_W = 16
)(
    input wire clk,
    input wire rst_n,
    input wire valid_in,
    input wire [DATA_W-1:0] data_in,
    input wire [1:0] quality_mode, // 0..N: choose scale
    output reg valid_out,
    output reg [DATA_W-1:0] data_out
);

reg signed [DATA_W+7:0] scaled;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 0;
        data_out <= 0;
    end else begin
        valid_out <= valid_in;
        case (quality_mode)
            2'd0: scaled <= data_in; // base
            2'd1: scaled <= data_in >>> 1; // example scale down
            default: scaled <= data_in;
        endcase
        data_out <= scaled[DATA_W-1:0];
    end
end

endmodule
