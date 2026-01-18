//====================================================
// Producer SFTM (Timing Model)
//====================================================
// Emits TileGroup descriptors at a programmable rate
//====================================================

module producer_sftm #(
    parameter integer FRAME_COLS = 1920,
    parameter integer FRAME_ROWS = 1080,
    parameter integer ROWS_PER_GROUP = 4,
    parameter integer BASE_PERIOD = 140,
    parameter integer JITTER = 2,
    parameter integer WIDTH = 16,
    parameter integer GID_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,

    // Configuration
    input  wire [WIDTH-1:0] tile_columns,
    input  wire [WIDTH-1:0] groups_total,

    // Output TileGroup (motion_ready implied)
    output reg  tile_valid,
    output reg  [GID_WIDTH-1:0] gid,
    output reg  [WIDTH-1:0] row_group_idx,
    output reg  [WIDTH-1:0] col_tile_idx,
    output reg  [WIDTH-1:0] col_start,
    output reg  [WIDTH-1:0] col_end
);

    // -------------------------
    // Internal state
    // -------------------------
    reg [31:0] cycle;
    reg [31:0] next_issue;
    reg [31:0] issued;

    reg [WIDTH-1:0] num_col_tiles;
    reg [WIDTH-1:0] period_per_tile;

    // Simple LFSR for jitter
    reg [7:0] lfsr;
    wire signed [7:0] jitter_val;

    assign jitter_val = (JITTER == 0) ? 0 :
                        (lfsr[3:0] - lfsr[7:4]); // small signed jitter

    // ceiling division
    function [WIDTH-1:0] ceil_div;
        input [WIDTH-1:0] a, b;
        begin
            ceil_div = (a + b - 1) / b;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle        <= 0;
            next_issue   <= 1;
            issued       <= 0;
            gid          <= 1;
            tile_valid   <= 1'b0;
            lfsr         <= 8'hA5;
        end else begin
            tile_valid <= 1'b0;
            cycle <= cycle + 1'b1;

            // LFSR advance
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5]};

            if (start && issued == 0) begin
                num_col_tiles   <= ceil_div(FRAME_COLS, tile_columns);
                period_per_tile <= (BASE_PERIOD / ceil_div(FRAME_COLS, tile_columns));
                next_issue      <= 1;
            end

            if (issued < groups_total && cycle >= next_issue) begin
                // Compute tile indices
                row_group_idx <= (issued / num_col_tiles);
                col_tile_idx  <= (issued % num_col_tiles);

                col_start <= (issued % num_col_tiles) * tile_columns;
                col_end   <= ((issued % num_col_tiles) * tile_columns + tile_columns - 1 < FRAME_COLS) ?
                             ((issued % num_col_tiles) * tile_columns + tile_columns - 1) :
                             (FRAME_COLS - 1);

                tile_valid <= 1'b1;
                issued     <= issued + 1'b1;
                gid        <= gid + 1'b1;

                // Schedule next issue with jitter
                next_issue <= cycle +
                              ((period_per_tile > 0) ? period_per_tile : 1) +
                              jitter_val;
            end
        end
    end

endmodule
