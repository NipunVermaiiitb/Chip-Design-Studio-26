// posta_conv_flat.sv
`timescale 1ns/1ps
module posta_conv_flat #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 6
)(
  input  wire                 clk,
  input  wire                 rst_n,
  input  wire                 valid_in,
  input  wire [DATA_W*16-1:0] patch_in_flat,   // 4x4 flattened
  output wire                 valid_out,
  output wire [ACC_W*4-1:0]   patch_out_flat   // 2x2 flattened
);

genvar r,c;
wire signed [DATA_W-1:0] in_patch [0:3][0:3];
wire signed [ACC_W-1:0] out_patch [0:1][0:1];
wire core_valid;

generate
  for (r=0;r<4;r=r+1) for (c=0;c<4;c=c+1)
    assign in_patch[r][c] = patch_in_flat[(r*4+c)*DATA_W +: DATA_W];
endgenerate

posta_conv #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_posta (
  .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
  .patch_in(in_patch),
  .valid_out(core_valid),
  .patch_out(out_patch)
);

generate
  for (r=0;r<2;r=r+1) for (c=0;c<2;c=c+1)
    assign patch_out_flat[(r*2+c)*ACC_W +: ACC_W] = out_patch[r][c];
endgenerate

assign valid_out = core_valid;

endmodule
