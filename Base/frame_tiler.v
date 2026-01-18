//====================================================
// Frame Tiler
//====================================================
// Splits a frame into tiles and emits one tile per cycle
//====================================================

module frame_tiler #(
    parameter integer WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,

    input  wire [WIDTH-1:0] frame_H,
    input  wire [WIDTH-1:0] frame_W,

    input  wire [WIDTH-1:0] tile_rows,
    input  wire [WIDTH-1:0] tile_cols_max,

    output reg  tile_valid,
    output reg  [WIDTH-1:0] tile_row_idx,
    output reg  [WIDTH-1:0] tile_col_idx,
    output reg  [WIDTH-1:0] tile_rows_out,
    output reg  [WIDTH-1:0] tile_cols_out,

    output reg  done
);

    reg [WIDTH-1:0] cur_row;
    reg [WIDTH-1:0] cur_col;

    reg active;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_row       <= 0;
            cur_col       <= 0;
            tile_row_idx  <= 0;
            tile_col_idx  <= 0;
            tile_rows_out <= 0;
            tile_cols_out <= 0;
            tile_valid    <= 1'b0;
            done          <= 1'b0;
            active        <= 1'b0;
        end else begin
            tile_valid <= 1'b0;
            done       <= 1'b0;

            if (start && !active) begin
                cur_row <= 0;
                cur_col <= 0;
                active  <= 1'b1;
            end
            else if (active) begin
                // Emit tile
                tile_row_idx <= cur_row;
                tile_col_idx <= cur_col;

                // Height (last row tile may be smaller)
                if (cur_row + tile_rows <= frame_H)
                    tile_rows_out <= tile_rows;
                else
                    tile_rows_out <= frame_H - cur_row;

                // Width (last column tile may be smaller)
                if (cur_col + tile_cols_max <= frame_W)
                    tile_cols_out <= tile_cols_max;
                else
                    tile_cols_out <= frame_W - cur_col;

                tile_valid <= 1'b1;

                // Advance column
                if (cur_col + tile_cols_max < frame_W) begin
                    cur_col <= cur_col + tile_cols_max;
                end else begin
                    cur_col <= 0;
                    // Advance row
                    if (cur_row + tile_rows < frame_H) begin
                        cur_row <= cur_row + tile_rows;
                    end else begin
                        active <= 1'b0;
                        done   <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
