`timescale 1ns/1ps

module tb_addr_gen;

    reg [31:0] frame_base_addr;
    reg [15:0] frame_stride_bytes;
    reg [15:0] bytes_per_pixel;

    reg [15:0] tile_row_start;
    reg [15:0] tile_col_start;
    reg [15:0] tile_rows;
    reg [15:0] tile_cols;
    reg [15:0] halo;

    reg is_reference;

    wire [31:0] base_addr;
    wire [31:0] length_bytes;

    integer error_count;

    addr_gen dut (
        .frame_base_addr(frame_base_addr),
        .frame_stride_bytes(frame_stride_bytes),
        .bytes_per_pixel(bytes_per_pixel),
        .tile_row_start(tile_row_start),
        .tile_col_start(tile_col_start),
        .tile_rows(tile_rows),
        .tile_cols(tile_cols),
        .halo(halo),
        .is_reference(is_reference),
        .base_addr(base_addr),
        .length_bytes(length_bytes)
    );

    initial begin
        error_count = 0;

        frame_base_addr    = 32'h1000_0000;
        frame_stride_bytes = 640;
        bytes_per_pixel    = 2;

        tile_row_start = 10;
        tile_col_start = 20;
        tile_rows      = 4;
        tile_cols      = 8;
        halo           = 1;

        // ------------------
        // Motion region
        // ------------------
        is_reference = 0;
        #1;

        if (base_addr !== (32'h1000_0000 + 10*640 + 20*2)) begin
            $display("ERROR: motion base_addr mismatch");
            error_count = error_count + 1;
        end

        if (length_bytes !== (4*8*2)) begin
            $display("ERROR: motion length mismatch");
            error_count = error_count + 1;
        end

        // ------------------
        // Reference region
        // ------------------
        is_reference = 1;
        #1;

        if (base_addr !== (32'h1000_0000 + 9*640 + 19*2)) begin
            $display("ERROR: reference base_addr mismatch");
            error_count = error_count + 1;
        end

        if (length_bytes !== ((4+2)*(8+2)*2)) begin
            $display("ERROR: reference length mismatch");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: addr_gen works as intended");
        else
            $display("FAIL: addr_gen has %0d errors", error_count);

        $finish;
    end

endmodule
