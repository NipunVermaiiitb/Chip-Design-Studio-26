// iqmu.v
// Inverse Quality Modulating Unit: dequantizes/decompresses features
// Inverse operation of QMU - scales UP instead of down
// Used in synthesis/decoding path before PreTA transform

`timescale 1ns/1ps
module iqmu #(
    parameter DATA_W = 16
)(
    input wire clk,
    input wire rst_n,
    input wire valid_in,
    input wire [DATA_W-1:0] data_in,
    input wire [1:0] quality_mode, // 0..N: must match QMU mode
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
            2'd0: scaled <= data_in;      // base (no scaling)
            2'd1: scaled <= data_in <<< 1; // inverse of QMU scale down (scale UP)
            2'd2: scaled <= data_in <<< 2; // more aggressive dequantization
            2'd3: scaled <= data_in <<< 3; // maximum dequantization
            default: scaled <= data_in;
        endcase
        
        // Saturate to prevent overflow
        if (scaled > $signed({1'b0, {(DATA_W-1){1'b1}}}))
            data_out <= {1'b0, {(DATA_W-1){1'b1}}};
        else if (scaled < $signed({1'b1, {(DATA_W-1){1'b0}}}))
            data_out <= {1'b1, {(DATA_W-1){1'b0}}};
        else
            data_out <= scaled[DATA_W-1:0];
    end
end

endmodule
