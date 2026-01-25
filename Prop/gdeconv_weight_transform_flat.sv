// gdeconv_weight_transform_flat.sv
`timescale 1ns/1ps
module gdeconv_weight_transform_flat #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 8
)(
  input  wire                 clk,
  input  wire                 rst_n,
  input  wire                 valid_in,
  input  wire [DATA_W*16-1:0] w_in_flat,       // 4x4
  output wire                 valid_out,
  output wire [ACC_W*36-1:0]  w_out_flat       // 6x6
);

genvar r,c;
wire signed [DATA_W-1:0] w_in [0:3][0:3];
wire signed [ACC_W-1:0] w_out [0:5][0:5];
wire core_valid;

generate
  for (r=0;r<4;r=r+1) for (c=0;c<4;c=c+1)
    assign w_in[r][c] = w_in_flat[(r*4+c)*DATA_W +: DATA_W];
endgenerate

gdeconv_weight_transform #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_gwt (
  .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
  .w_in(w_in), .valid_out(core_valid), .w_out(w_out)
);

generate
  for (r=0;r<6;r=r+1) for (c=0;c<6;c=c+1)
    assign w_out_flat[(r*6+c)*ACC_W +: ACC_W] = w_out[r][c];
endgenerate

assign valid_out = core_valid;

endmodule
