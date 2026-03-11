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
    input wire signed [DATA_W-1:0] data_in,
    input wire [1:0] quality_mode, // 0..N: must match QMU mode
    output reg valid_out,
    output reg signed [DATA_W-1:0] data_out
);

localparam integer Q_FRAC = 8; // Q8.8 fixed-point for scale

reg signed [15:0] phi_q;
reg signed [15:0] theta_q;
reg signed [31:0] relu_q;
reg signed [15:0] scale_q;
reg signed [DATA_W+15:0] mult_full;
reg signed [DATA_W+7:0] scaled;

always @(*) begin
    // Minimal IQML-style parameter selector.
    // For now, use theta=0 and phi=(S-1) in Q8.8 so that:
    //   scale = 1 + ReLU(phi)  => constant per-quality scale.
    // 0: 1.0, 1: 2.0, 2: 4.0, 3: 8.0
    theta_q = 16'sd0;
    case (quality_mode)
        2'd0: phi_q = 16'sd0;     // (1-1)
        2'd1: phi_q = 16'sd256;   // (2-1)
        2'd2: phi_q = 16'sd768;   // (4-1)
        2'd3: phi_q = 16'sd1792;  // (8-1)
        default: phi_q = 16'sd0;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 0;
        data_out <= 0;
    end else begin
        valid_out <= valid_in;

        // relu_q models ReLU(theta*x + phi) in Q8.8.
        // With theta=0, this is just ReLU(phi_q).
        relu_q = $signed(phi_q);
        if (relu_q < 0) relu_q = 0;

        scale_q = 16'sd256 + relu_q[15:0]; // 1.0 + relu

        mult_full = $signed(data_in) * $signed(scale_q);
        scaled = mult_full >>> Q_FRAC;

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
