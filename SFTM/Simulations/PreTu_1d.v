module PreTu_1d #(parameter DW = 16)(
    input  mode,   // 1 = RFConv, 0 = RFDeConv (future)
    input  signed [DW-1:0] X0,
    input  signed [DW-1:0] X1,
    input  signed [DW-1:0] X2,
    input  signed [DW-1:0] X3,

    output reg signed [DW:0] Y0,
    output reg signed [DW:0] Y1,
    output reg signed [DW:0] Y2,
    output reg signed [DW:0] Y3
);

    always @(*) begin
        if (mode) begin
            Y0 =  X0 - X2;
            Y1 =  X1 + X2;
            Y2 = -X1 + X2;
            Y3 =  X1 - X3;
        end else begin
            Y0 = {(DW+1){1'b0}};
            Y1 = {(DW+1){1'b0}};
            Y2 = {(DW+1){1'b0}};
            Y3 = {(DW+1){1'b0}};
        end
    end

endmodule
