// gdeconv_weight_transform.sv
`timescale 1ns/1ps
module gdeconv_weight_transform #(
  parameter DATA_W = 16,
  parameter ACC_W  = DATA_W + 8
)(
  input  wire                        clk,
  input  wire                        rst_n,
  input  wire                        valid_in,
  input  wire signed [DATA_W-1:0]    w_in [0:3][0:3], // 4x4 weights
  output reg                         valid_out,
  output reg signed [ACC_W-1:0]      w_out [0:5][0:5] // 6x6 transformed weights
);

// G matrix (paper Eq.18)
localparam signed [1:0] G [0:5][0:3] = '{
 '{0,0,0,1},
 '{0,1,0,1},
 '{0,1,0,0},
 '{0,0,1,0},
 '{1,0,1,0},
 '{1,0,0,0}
};

genvar i,j;
wire signed [ACC_W-1:0] Ttmp [0:5][0:3];

generate
  for (i=0;i<6;i=i+1) begin
    for (j=0;j<4;j=j+1) begin
      wire signed [ACC_W-1:0] p0 = (G[i][0]==1) ? {{(ACC_W-DATA_W){w_in[0][j][DATA_W-1]}}, w_in[0][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p1 = (G[i][1]==1) ? {{(ACC_W-DATA_W){w_in[1][j][DATA_W-1]}}, w_in[1][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p2 = (G[i][2]==1) ? {{(ACC_W-DATA_W){w_in[2][j][DATA_W-1]}}, w_in[2][j]} : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] p3 = (G[i][3]==1) ? {{(ACC_W-DATA_W){w_in[3][j][DATA_W-1]}}, w_in[3][j]} : {ACC_W{1'b0}};
      assign Ttmp[i][j] = p0 + p1 + p2 + p3;
    end
  end
endgenerate

generate
  for (i=0;i<6;i=i+1) begin
    for (j=0;j<6;j=j+1) begin
      wire signed [ACC_W-1:0] q0 = (G[j][0]==1) ? Ttmp[i][0] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q1 = (G[j][1]==1) ? Ttmp[i][1] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q2 = (G[j][2]==1) ? Ttmp[i][2] : {ACC_W{1'b0}};
      wire signed [ACC_W-1:0] q3 = (G[j][3]==1) ? Ttmp[i][3] : {ACC_W{1'b0}};
      wire signed [ACC_W+3:0] sum_all = q0 + q1 + q2 + q3;
      always @(posedge clk or negedge rst_n) begin
        if (!rst_n) w_out[i][j] <= {ACC_W{1'b0}};
        else w_out[i][j] <= sum_all[ACC_W-1:0];
      end
    end
  end
endgenerate

always @(posedge clk or negedge rst_n) begin
  if (!rst_n) valid_out <= 1'b0;
  else valid_out <= valid_in;
end

endmodule
