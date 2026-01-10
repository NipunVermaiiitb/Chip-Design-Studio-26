module PreTu #(parameter DW = 16)(
    // Row 0
    input signed [DW-1:0] X00, X01, X02, X03,
    // Row 1
    input signed [DW-1:0] X10, X11, X12, X13,
    // Row 2
    input signed [DW-1:0] X20, X21, X22, X23,
    // Row 3
    input signed [DW-1:0] X30, X31, X32, X33,

    // Outputs
    output signed [DW+1:0] Y00, Y01, Y02, Y03,
    output signed [DW+1:0] Y10, Y11, Y12, Y13,
    output signed [DW+1:0] Y20, Y21, Y22, Y23,
    output signed [DW+1:0] Y30, Y31, Y32, Y33
);

    // Row transform outputs
    wire signed [DW:0]
        r00, r01, r02, r03,
        r10, r11, r12, r13,
        r20, r21, r22, r23,
        r30, r31, r32, r33;

    // --------------------
    // Stage 1: Rows
    // --------------------
    PreTu_1d #(DW) R0 (1'b1, X00, X01, X02, X03, r00, r01, r02, r03);
    PreTu_1d #(DW) R1 (1'b1, X10, X11, X12, X13, r10, r11, r12, r13);
    PreTu_1d #(DW) R2 (1'b1, X20, X21, X22, X23, r20, r21, r22, r23);
    PreTu_1d #(DW) R3 (1'b1, X30, X31, X32, X33, r30, r31, r32, r33);

    // --------------------
    // Stage 2: Columns
    // --------------------
    PreTu_1d #(DW+1) C0 (1'b1, r00, r10, r20, r30, Y00, Y10, Y20, Y30);
    PreTu_1d #(DW+1) C1 (1'b1, r01, r11, r21, r31, Y01, Y11, Y21, Y31);
    PreTu_1d #(DW+1) C2 (1'b1, r02, r12, r22, r32, Y02, Y12, Y22, Y32);
    PreTu_1d #(DW+1) C3 (1'b1, r03, r13, r23, r33, Y03, Y13, Y23, Y33);

endmodule
