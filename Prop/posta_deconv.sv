// posta_deconv.sv
`timescale 1ns/1ps
module posta_deconv #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 8
)(
  input  wire                     clk,
  input  wire                     rst_n,
  input  wire                     valid_in,
  input  wire signed [DATA_W-1:0] patch_in [0:5][0:5],
  output reg                      valid_out,
  output reg signed [ACC_W-1:0]   patch_out [0:3][0:3]
);

// A^T_DeConv (Eq.19)
localparam signed [1:0] AT [0:3][0:5] = '{
  '{ 1,1,0,0,0,0 },
  '{ 0,0,0,1,1,0 },
  '{ 0,1,1,0,0,0 },
  '{ 0,0,0,0,1,1 }
};

genvar i,j;
wire signed [ACC_W-1:0] tmp [0:3][0:5];

generate
  for (i=0;i<4;i=i+1) begin
    for (j=0;j<6;j=j+1) begin
      wire signed [ACC_W-1:0] t0 = (AT[i][0]==1) ? {{(ACC_W-DATA_W){patch_in[0][j][DATA_W-1]}}, patch_in[0][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] t1 = (AT[i][1]==1) ? {{(ACC_W-DATA_W){patch_in[1][j][DATA_W-1]}}, patch_in[1][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] t2 = (AT[i][2]==1) ? {{(ACC_W-DATA_W){patch_in[2][j][DATA_W-1]}}, patch_in[2][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] t3 = (AT[i][3]==1) ? {{(ACC_W-DATA_W){patch_in[3][j][DATA_W-1]}}, patch_in[3][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] t4 = (AT[i][4]==1) ? {{(ACC_W-DATA_W){patch_in[4][j][DATA_W-1]}}, patch_in[4][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] t5 = (AT[i][5]==1) ? {{(ACC_W-DATA_W){patch_in[5][j][DATA_W-1]}}, patch_in[5][j]} : {ACC_W{1'b0}};
      assign tmp[i][j] = t0 + t1 + t2 + t3 + t4 + t5;
    end
  end
endgenerate

generate
  for (i=0;i<4;i=i+1) begin
    for (j=0;j<4;j=j+1) begin
      wire signed [ACC_W-1:0] q0 = (AT[j][0]==1) ? tmp[i][0] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q1 = (AT[j][1]==1) ? tmp[i][1] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q2 = (AT[j][2]==1) ? tmp[i][2] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q3 = (AT[j][3]==1) ? tmp[i][3] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q4 = (AT[j][4]==1) ? tmp[i][4] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q5 = (AT[j][5]==1) ? tmp[i][5] : {ACC_W{1'b0}};
      wire signed [ACC_W+4:0] sum_all = q0 + q1 + q2 + q3 + q4 + q5;
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
