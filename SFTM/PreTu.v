//X =
//[ X0[0] X0[1] X0[2] X0[3] ]
//[ X1[0] X1[1] X1[2] X1[3] ]
//[ X2[0] X2[1] X2[2] X2[3] ]
//[ X3[0] X3[1] X3[2] X3[3] ]
module PreTu #(
    parameter DW = 16
)(
    input   signed [DW-1:0] X0[3:0],
    input   signed [DW-1:0] X1[3:0],
    input   signed [DW-1:0] X2[3:0],
    input   signed [DW-1:0] X3[3:0],

    output  signed [DW:0]   Y0[3:0],
    output  signed [DW:0]   Y1[3:0],
    output  signed [DW:0]   Y2[3:0],
    output  signed [DW:0]   Y3[3:0]
);

    // Intermediate after row transform
    wire signed [DW:0] row_t [3:0][3:0];

    // -------------------------------
    // Stage 1: ROW transform (X * B)
    // -------------------------------
    PreTu_1d #(.DW(DW)) r0 (
        .mode(1'b1),
        .X0(X0[0]), .X1(X0[1]), .X2(X0[2]), .X3(X0[3]),
        .Y0(row_t[0][0]), .Y1(row_t[0][1]),
        .Y2(row_t[0][2]), .Y3(row_t[0][3])
    );

    PreTu_1d #(.DW(DW)) r1 (
        .mode(1'b1),
        .X0(X1[0]), .X1(X1[1]), .X2(X1[2]), .X3(X1[3]),
        .Y0(row_t[1][0]), .Y1(row_t[1][1]),
        .Y2(row_t[1][2]), .Y3(row_t[1][3])
    );

    PreTu_1d #(.DW(DW)) r2 (
        .mode(1'b1),
        .X0(X2[0]), .X1(X2[1]), .X2(X2[2]), .X3(X2[3]),
        .Y0(row_t[2][0]), .Y1(row_t[2][1]),
        .Y2(row_t[2][2]), .Y3(row_t[2][3])
    );

    PreTu_1d #(.DW(DW)) r3 (
        .mode(1'b1),
        .X0(X3[0]), .X1(X3[1]), .X2(X3[2]), .X3(X3[3]),
        .Y0(row_t[3][0]), .Y1(row_t[3][1]),
        .Y2(row_t[3][2]), .Y3(row_t[3][3])
    );

    // -----------------------------------
    // Stage 2: COLUMN transform (Bᵀ * row)
    // -----------------------------------
    genvar c;
    generate
        for (c = 0; c < 4; c = c + 1) begin : COL_STAGE
            PreTu_1d #(.DW(DW+1)) col (
                .mode(1'b1),
                .X0(row_t[0][c]),
                .X1(row_t[1][c]),
                .X2(row_t[2][c]),
                .X3(row_t[3][c]),
                .Y0(Y0[c]),
                .Y1(Y1[c]),
                .Y2(Y2[c]),
                .Y3(Y3[c])
            );
        end
    endgenerate

endmodule

    endgenerate

endmodule

