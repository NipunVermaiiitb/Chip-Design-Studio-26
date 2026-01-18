`timescale 1ns/1ps

module tb_producer_sftm;

    localparam FRAME_COLS = 64;
    localparam FRAME_ROWS = 32;
    localparam ROWS_PER_GROUP = 4;

    reg clk, rst_n, start;
    reg [15:0] tile_columns;
    reg [15:0] groups_total;

    wire tile_valid;
    wire [15:0] gid;
    wire [15:0] row_group_idx;
    wire [15:0] col_tile_idx;
    wire [15:0] col_start;
    wire [15:0] col_end;

    integer tile_count;
    integer error_count;

    producer_sftm #(
        .FRAME_COLS(FRAME_COLS),
        .FRAME_ROWS(FRAME_ROWS),
        .ROWS_PER_GROUP(ROWS_PER_GROUP),
        .BASE_PERIOD(20),
        .JITTER(0)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .tile_columns(tile_columns),
        .groups_total(groups_total),
        .tile_valid(tile_valid),
        .gid(gid),
        .row_group_idx(row_group_idx),
        .col_tile_idx(col_tile_idx),
        .col_start(col_start),
        .col_end(col_end)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        tile_columns = 16;
        groups_total = 8;
        tile_count = 0;
        error_count = 0;

        #20 rst_n = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        repeat (200) begin
            @(posedge clk);
            if (tile_valid) begin
                tile_count = tile_count + 1;

                // Bounds check
                if (col_start > col_end || col_end >= FRAME_COLS) begin
                    $display("ERROR: invalid col range %0d-%0d", col_start, col_end);
                    error_count = error_count + 1;
                end
            end
        end

        if (tile_count !== groups_total) begin
            $display("ERROR: expected %0d tiles, got %0d", groups_total, tile_count);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: producer_sftm works as intended");
        else
            $display("FAIL: producer_sftm has %0d errors", error_count);

        $finish;
    end

endmodule
