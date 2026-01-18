//====================================================
// Address Generator
//====================================================
// Computes base address and length for
// motion / reference tile regions
//====================================================

module addr_gen #(
    parameter integer ADDR_WIDTH = 32,
    parameter integer DIM_WIDTH  = 16
)(
    // Frame parameters
    input wire [ADDR_WIDTH-1:0] frame_base_addr,
    input wire [DIM_WIDTH-1:0]  frame_stride_bytes, // bytes per row
    input wire [DIM_WIDTH-1:0]  bytes_per_pixel,

    // Tile parameters
    input wire [DIM_WIDTH-1:0]  tile_row_start,
    input wire [DIM_WIDTH-1:0]  tile_col_start,
    input wire [DIM_WIDTH-1:0]  tile_rows,
    input wire [DIM_WIDTH-1:0]  tile_cols,

    // Reference region expansion
    input wire [DIM_WIDTH-1:0]  halo,

    // Control
    input wire is_reference,   // 0 = motion, 1 = reference

    // Outputs
    output reg  [ADDR_WIDTH-1:0] base_addr,
    output reg  [ADDR_WIDTH-1:0] length_bytes
);

    reg [DIM_WIDTH-1:0] start_row;
    reg [DIM_WIDTH-1:0] start_col;
    reg [DIM_WIDTH-1:0] rows_eff;
    reg [DIM_WIDTH-1:0] cols_eff;

    always @(*) begin
        // Expand for reference region
        if (is_reference) begin
            start_row = (tile_row_start > halo) ? tile_row_start - halo : 0;
            start_col = (tile_col_start > halo) ? tile_col_start - halo : 0;
            rows_eff  = tile_rows + (halo << 1);
            cols_eff  = tile_cols + (halo << 1);
        end else begin
            start_row = tile_row_start;
            start_col = tile_col_start;
            rows_eff  = tile_rows;
            cols_eff  = tile_cols;
        end

        // Base address
        base_addr =
            frame_base_addr +
            start_row * frame_stride_bytes +
            start_col * bytes_per_pixel;

        // Length in bytes
        length_bytes =
            rows_eff * cols_eff * bytes_per_pixel;
    end

endmodule
