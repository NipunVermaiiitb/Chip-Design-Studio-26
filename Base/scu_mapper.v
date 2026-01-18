//====================================================
// SCU Mapper
// Maps (out_ch_idx, in_ch_idx) -> (SCU row, SCU col)
//====================================================

module scu_mapper #(
    parameter integer POF = 4,    // SCU rows
    parameter integer PIF = 12,   // SCU columns
    parameter integer IDX_WIDTH = 16
)(
    input  wire [IDX_WIDTH-1:0] out_idx,
    input  wire [IDX_WIDTH-1:0] in_idx,

    input  wire [IDX_WIDTH-1:0] out_ch,
    input  wire [IDX_WIDTH-1:0] in_ch,

    output reg  [$clog2(POF)-1:0] scu_row,
    output reg  [$clog2(PIF)-1:0] scu_col,
    output reg  [$clog2(POF*PIF)-1:0] scu_linear
);

    reg [IDX_WIDTH-1:0] out_per_row;
    reg [IDX_WIDTH-1:0] in_per_col;

    reg [IDX_WIDTH-1:0] row_tmp;
    reg [IDX_WIDTH-1:0] col_tmp;

    // combinational mapping
    always @(*) begin
        // ceiling division
        out_per_row = (out_ch + POF - 1) / POF;
        in_per_col  = (in_ch  + PIF - 1) / PIF;

        // integer division
        row_tmp = out_idx / out_per_row;
        col_tmp = in_idx  / in_per_col;

        // saturation
        if (row_tmp >= POF)
            scu_row = POF - 1;
        else
            scu_row = row_tmp[$clog2(POF)-1:0];

        if (col_tmp >= PIF)
            scu_col = PIF - 1;
        else
            scu_col = col_tmp[$clog2(PIF)-1:0];

        // linear index
        scu_linear = scu_row * PIF + scu_col;
    end

endmodule
