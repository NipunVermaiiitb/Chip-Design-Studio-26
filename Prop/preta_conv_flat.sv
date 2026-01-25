// preta_conv_flat.sv
`timescale 1ns/1ps
module preta_conv_flat #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 6
)(
  input  wire                   clk,
  input  wire                   rst_n,
  input  wire                   valid_in,
  input  wire [DATA_W*16-1:0]   patch_in_flat,  // 4x4 flattened (row-major)
  output wire                   valid_out,
  output wire [ACC_W*16-1:0]    patch_out_flat  // 4x4 flattened
);

genvar r,c;
wire signed [DATA_W-1:0] patch_in [0:3][0:3];
wire signed [ACC_W-1:0] patch_out [0:3][0:3];
wire core_valid_out;

// unpack
generate
  for (r=0; r<4; r=r+1) begin : UNPK_R
    for (c=0; c<4; c=c+1) begin : UNPK_C
      assign patch_in[r][c] = patch_in_flat[(r*4 + c)*DATA_W +: DATA_W];
    end
  end
endgenerate

// instantiate core
preta_conv #(.DATA_W(DATA_W), .ACC_W(ACC_W)) u_preta (
  .clk(clk), .rst_n(rst_n),
  .valid_in(valid_in),
  .patch_in(patch_in),
  .valid_out(core_valid_out),
  .patch_out(patch_out)
);

// pack
generate
  for (r=0; r<4; r=r+1) begin : PK_R
    for (c=0; c<4; c=c+1) begin : PK_C
      assign patch_out_flat[(r*4 + c)*ACC_W +: ACC_W] = patch_out[r][c];
    end
  end
endgenerate

assign valid_out = core_valid_out;

endmodule
