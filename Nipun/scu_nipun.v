// EACH SCU TAKES IN 18 WEIGHT VALUES(DENSE), 16 ACTIVATION VALUES, 18 INDEXES
module scu #(
    parameter A_bits= 12,
    parameter W_bits=16,
    parameter I_bits=6
)(
    input mode, //Mode=1 Rfconv and Mode=0 Rfdeconv
    input wire signed [W_bits-1:0] weights[17:0],
    input wire signed [A_bits-1:0] input_tile[35:0],
    input wire signed [I_bits-1:0] indexes[17:0],
    output wire signed [A_bits-1:0] OC0 [15:0],
    output wire signed [A_bits-1:0] OC1 [15:0],
    output wire signed [A_bits-1:0] OC2 [15:0]
);
//FIRST 6 WEIGHT VALUES ARE FOR OC0 AND FIRST 6 INDEX VALUES ARE FOR OC0
wire [A_bits-1:0] Y [17:0];
wire [27:0] partial_product [17:0];
if(mode==1) begin
    wire signed [A_bits-1:0] activation[15:0]=input_tile[0:15]; // The activation is first 16 bits of input_tile if mode=1
end
else begin
    assign activation=input_tile //When mode=0 they are both same
end
wire [31:0] accu[47:0];
genvar i;
generate
    for (i = 0; i < 18; i = i + 1) begin : assigningY
        assign Y[i]=activation[indexes[i]];
    end
endgenerate

genvar j;
generate
    for (j = 0; j < 18; j = j + 1) begin : multiplication
        assign partial_product[j]=Y[j]*weights[j];
    end
endgenerate

genvar k;
generate
    for (k = 0; k < 18; k = k + 1) begin : accumulation
    if(k<6 && mode) begin 
        assign accu[indexes[k]]=accu[indexes[k]]+partial_product[k];
    end
    else if(5<k<12 && mode) begin
        assign accu[indexes[k]+16]=accu[indexes[k]+16]+partial_product[k];
    end
    else if(11<k<18 && mode) begin
        assign accu[indexes[k]+32]=accu[indexes[k]+32]+partial_product[k];
    end
    else if (mode ==0)begin
        assign accu[indexes[k]]=accu[indexes[k]]+partial_product[k];
    end
    end
        
endgenerate

assign OC0=[31:20]accu[0:15];
assign OC1=[31:20]accu[16:31];
assign OC2=[31:20]accu[32:47];
endmodule