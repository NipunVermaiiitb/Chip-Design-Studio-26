// addr_conv_paper.sv
`timescale 1ns/1ps

module addr_conv_paper #(
    parameter int DATA_W = 16,
    parameter int FRAC_BITS = 8,
    parameter int IDX_W = 4,
    parameter int MAX_X = 16,
    parameter int MAX_Y = 16
)(
    input  logic signed [DATA_W-1:0] off_x,
    input  logic signed [DATA_W-1:0] off_y,
    input  logic [IDX_W-1:0] base_x0,
    input  logic [IDX_W-1:0] base_y0,

    output logic [IDX_W-1:0] base_x,
    output logic [IDX_W-1:0] base_y,
    output logic [FRAC_BITS-1:0] frac_x,
    output logic [FRAC_BITS-1:0] frac_y
);
    // base_x0/base_y0 are integer pixels; off_* are Q(FRAC_BITS)
    logic signed [DATA_W-1:0] sumx, sumy;
    logic signed [DATA_W-1:0] base_qx, base_qy;
    logic signed [DATA_W-1:0] sx, sy;
    logic signed [DATA_W-FRAC_BITS-1:0] ix, iy;

    always_comb begin
        base_qx = $signed({{(DATA_W-IDX_W){1'b0}}, base_x0}) <<< FRAC_BITS;
        base_qy = $signed({{(DATA_W-IDX_W){1'b0}}, base_y0}) <<< FRAC_BITS;

        sumx = base_qx + off_x;
        sumy = base_qy + off_y;

        sx = sumx;
        sy = sumy;

        ix = sx >>> FRAC_BITS;
        iy = sy >>> FRAC_BITS;

        // frac are low bits
        frac_x = sx[FRAC_BITS-1:0];
        frac_y = sy[FRAC_BITS-1:0];

        // clip integer part to valid range [0..MAX-2] since we need x+1,y+1
        if (ix < 0) base_x = '0;
        else if (ix > (MAX_X-2)) base_x = IDX_W'(MAX_X-2);
        else base_x = ix[IDX_W-1:0];

        if (iy < 0) base_y = '0;
        else if (iy > (MAX_Y-2)) base_y = IDX_W'(MAX_Y-2);
        else base_y = iy[IDX_W-1:0];
    end
endmodule
