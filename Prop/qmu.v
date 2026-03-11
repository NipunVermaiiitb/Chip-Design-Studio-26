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
    input wire signed [DATA_W-1:0] data_in,
    input wire [1:0] quality_mode, // 0..N: choose scale
    output reg valid_out,
    output reg signed [DATA_W-1:0] data_out
);

localparam integer Q_FRAC = 8; // Q8.8 fixed-point for scale

reg signed [15:0] scale_q;
reg signed [DATA_W+15:0] mult_full;
reg signed [DATA_W+7:0] scaled;

always @(*) begin
    // Approximate analysis-side QML as a small runtime-selected linear scale.
    // 0: 1.0, 1: 0.5, 2: 0.25, 3: 0.125
    case (quality_mode)
        2'd0: scale_q = 16'sd256; // 1.0
        2'd1: scale_q = 16'sd128; // 0.5
        2'd2: scale_q = 16'sd64;  // 0.25
        2'd3: scale_q = 16'sd32;  // 0.125
        default: scale_q = 16'sd256;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 0;
        data_out <= 0;
    end else begin
        valid_out <= valid_in;

        mult_full = $signed(data_in) * $signed(scale_q);
        scaled = mult_full >>> Q_FRAC;

        // Saturate to signed DATA_W to avoid wrap
        if (scaled > $signed({1'b0, {(DATA_W-1){1'b1}}}))
            data_out <= {1'b0, {(DATA_W-1){1'b1}}};
        else if (scaled < $signed({1'b1, {(DATA_W-1){1'b0}}}))
            data_out <= {1'b1, {(DATA_W-1){1'b0}}};
        else
            data_out <= scaled[DATA_W-1:0];
    end
end

endmodule
