// posta_deconv_flat.sv
`timescale 1ns/1ps
module posta_deconv_flat #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 8
)(
  input  wire                 clk,
  input  wire                 rst_n,
  input  wire                 valid_in,
  input  wire [DATA_W*36-1:0] patch_in_flat,  // 6x6 flattened
  output wire                 valid_out,
  output wire [ACC_W*16-1:0]  patch_out_flat  // 4x4 flattened
);

genvar r,c;
wire signed [DATA_W-1:0] p_in [0:5][0:5];
wire signed [ACC_W-1:0] p_out [0:3][0:3];
wire core_valid;

generate
  for (r=0;r<6;r=r+1) for (c=0;c<6;c=c+1)
    assign p_in[r][c] = patch_in_flat[(r*6+c)*DATA_W +: DATA_W];
endgenerate

posta_deconv #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_postd (
  .clk(clk), .rst_n(rst_n), .valid_in(valid_in),
  .patch_in(p_in), .valid_out(core_valid), .patch_out(p_out)
);

generate
  for (r=0;r<4;r=r+1) for (c=0;c<4;c=c+1)
    assign patch_out_flat[(r*4+c)*ACC_W +: ACC_W] = p_out[r][c];
endgenerate

assign valid_out = core_valid;

endmodule
