module PreTu_1d #(
    parameter DW = 16
)(
    input   mode,   // 1 = RFConv, 0 = RFDeConv (future)
    input   signed [DW-1:0] X0,
    input   signed [DW-1:0] X1,
    input   signed [DW-1:0] X2,
    input   signed [DW-1:0] X3,

    output  signed [DW:0]   Y0,
    output  signed [DW:0]   Y1,
    output  signed [DW:0]   Y2,
    output  signed [DW:0]   Y3
);

    always_comb begin
        if (mode) begin
            // RFConv: Eq. (16)
            Y0 =  X0 - X2;
            Y1 =  X1 + X2;
            Y2 = -X1 + X2;
            Y3 =  X1 - X3;
        end else begin
            // Placeholder for RFDeConv (safe default)
            Y0 = '0;
            Y1 = '0;
            Y2 = '0;
            Y3 = '0;
        end
    end

endmodule
