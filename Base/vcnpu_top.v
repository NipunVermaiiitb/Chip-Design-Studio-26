//====================================================
// VCNPU Top-Level
//====================================================

module vcnpu_top #(
    parameter integer NUM_CORES = 2,
    parameter integer POF = 2,
    parameter integer PIF = 3,
    parameter integer MULT_WIDTH = 16,
    parameter integer WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    // Frame control
    input  wire start,
    input  wire [WIDTH-1:0] frame_H,
    input  wire [WIDTH-1:0] frame_W,

    // Tile configuration
    input  wire [WIDTH-1:0] tile_rows,
    input  wire [WIDTH-1:0] tile_cols_max,

    // Layer control
    input  wire is_dfconv,

    // Precomputed SCU loads (from mask cache)
    input  wire [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat,

    output wire busy,
    output wire done
);

    // ------------------------------------------------
    // Frame tiler wires
    // ------------------------------------------------
    wire tile_valid;
    wire tiler_done;

    wire [WIDTH-1:0] tile_row_idx;
    wire [WIDTH-1:0] tile_col_idx;
    wire [WIDTH-1:0] tile_rows_out;
    wire [WIDTH-1:0] tile_cols_out;

    // ------------------------------------------------
    // Frame Tiler
    // ------------------------------------------------
    frame_tiler #(.WIDTH(WIDTH)) u_tiler (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .frame_H(frame_H),
        .frame_W(frame_W),
        .tile_rows(tile_rows),
        .tile_cols_max(tile_cols_max),
        .tile_valid(tile_valid),
        .tile_row_idx(tile_row_idx),
        .tile_col_idx(tile_col_idx),
        .tile_rows_out(tile_rows_out),
        .tile_cols_out(tile_cols_out),
        .done(tiler_done)
    );

    // ------------------------------------------------
    // Controller
    // ------------------------------------------------
    controller #(
        .NUM_CORES(NUM_CORES),
        .POF(POF),
        .PIF(PIF),
        .MULT_WIDTH(MULT_WIDTH)
    ) u_controller (
        .clk(clk),
        .rst_n(rst_n),
        .tile_valid(tile_valid),
        .is_dfconv(is_dfconv),
        .rows(tile_rows_out),
        .cols(tile_cols_out),
        .in_ch(16'd36),
        .out_ch(16'd36),
        .assigned_mults_flat(assigned_mults_flat),
        .start(start),
        .busy(busy),
        .done(done)
    );

endmodule
