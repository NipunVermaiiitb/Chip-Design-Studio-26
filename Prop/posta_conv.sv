// posta_conv.sv
`timescale 1ns/1ps
module posta_conv #(
    parameter DATA_W = 16,
    parameter ACC_W  = DATA_W + 6
)(
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     valid_in,
    input  wire signed [DATA_W-1:0] patch_in [0:3][0:3], // 4x4 U
    output reg                      valid_out,
    output reg signed [ACC_W-1:0]   patch_out [0:1][0:1] // 2x2 V
);

// A^T_conv per paper
localparam signed [2:0] AT [0:1][0:3] = '{
  '{ 1, 1, 1, 0 },
  '{ 0, 1,-1,-1 }
};

genvar i,j;
wire signed [ACC_W-1:0] tmp [0:1][0:3];

generate
  for (i=0;i<2;i=i+1) begin
    for (j=0;j<4;j=j+1) begin
      wire signed [ACC_W-1:0] p0 = (AT[i][0]==1) ? {{(ACC_W-DATA_W){patch_in[0][j][DATA_W-1]}}, patch_in[0][j]} :
                                   (AT[i][0]==-1) ? -{{(ACC_W-DATA_W){patch_in[0][j][DATA_W-1]}}, patch_in[0][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p1 = (AT[i][1]==1) ? {{(ACC_W-DATA_W){patch_in[1][j][DATA_W-1]}}, patch_in[1][j]} :
                                   (AT[i][1]==-1) ? -{{(ACC_W-DATA_W){patch_in[1][j][DATA_W-1]}}, patch_in[1][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p2 = (AT[i][2]==1) ? {{(ACC_W-DATA_W){patch_in[2][j][DATA_W-1]}}, patch_in[2][j]} :
                                   (AT[i][2]==-1) ? -{{(ACC_W-DATA_W){patch_in[2][j][DATA_W-1]}}, patch_in[2][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p3 = (AT[i][3]==1) ? {{(ACC_W-DATA_W){patch_in[3][j][DATA_W-1]}}, patch_in[3][j]} :
                                   (AT[i][3]==-1) ? -{{(ACC_W-DATA_W){patch_in[3][j][DATA_W-1]}}, patch_in[3][j]} : {ACC_W{1'b0}};
      assign tmp[i][j] = p0 + p1 + p2 + p3;
    end
  end
endgenerate

generate
  for (i=0;i<2;i=i+1) begin
    for (j=0;j<2;j=j+1) begin
      wire signed [ACC_W-1:0] q0 = (AT[j][0]==1) ? tmp[i][0] : (AT[j][0]==-1 ? -tmp[i][0] : {ACC_W{1'b0}});
      wire signed [ACC_W-1:0] q1 = (AT[j][1]==1) ? tmp[i][1] : (AT[j][1]==-1 ? -tmp[i][1] : {ACC_W{1'b0}});
      wire signed [ACC_W-1:0] q2 = (AT[j][2]==1) ? tmp[i][2] : (AT[j][2]==-1 ? -tmp[i][2] : {ACC_W{1'b0}});
      wire signed [ACC_W-1:0] q3 = (AT[j][3]==1) ? tmp[i][3] : (AT[j][3]==-1 ? -tmp[i][3] : {ACC_W{1'b0}});
      wire signed [ACC_W+3:0] sum_all = q0 + q1 + q2 + q3;
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) patch_out[i][j] <= {ACC_W{1'b0}};
        else patch_out[i][j] <= sum_all[ACC_W-1:0];
      end
    end
  end
endgenerate

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) valid_out <= 1'b0;
  else valid_out <= valid_in;
end

endmodule
