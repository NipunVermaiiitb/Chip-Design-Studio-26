`timescale 1ns/1ps

module tb_frame_tiler;

    localparam WIDTH = 16;

    reg clk, rst_n;
    reg start;

    reg [WIDTH-1:0] frame_H, frame_W;
    reg [WIDTH-1:0] tile_rows, tile_cols_max;

    wire tile_valid;
    wire [WIDTH-1:0] tile_row_idx, tile_col_idx;
    wire [WIDTH-1:0] tile_rows_out, tile_cols_out;
    wire done;

    integer error_count;
    integer tile_count;
    integer exp_tiles;

    frame_tiler #(.WIDTH(WIDTH)) dut (
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
        .done(done)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        error_count = 0;
        tile_count = 0;

        frame_H = 10;
        frame_W = 14;
        tile_rows = 4;
        tile_cols_max = 5;

        // Expected:
        // Rows: ceil(10/4) = 3
        // Cols: ceil(14/5) = 3
        exp_tiles = 3 * 3;

        #20 rst_n = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        while (!done) begin
            @(posedge clk);
            if (tile_valid) begin
                tile_count = tile_count + 1;

                // Check bounds
                if (tile_row_idx + tile_rows_out > frame_H) begin
                    $display("ERROR: tile row overflow");
                    error_count = error_count + 1;
                end
                if (tile_col_idx + tile_cols_out > frame_W) begin
                    $display("ERROR: tile col overflow");
                    error_count = error_count + 1;
                end
            end
        end

        if (tile_count !== exp_tiles) begin
            $display("ERROR: Expected %0d tiles, got %0d",
                     exp_tiles, tile_count);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: frame_tiler works as intended");
        else
            $display("FAIL: frame_tiler has %0d errors", error_count);

        $finish;
    end

endmodule
