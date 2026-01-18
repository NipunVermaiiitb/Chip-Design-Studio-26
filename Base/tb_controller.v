`timescale 1ns/1ps

module tb_controller;

    localparam NUM_CORES = 2;
    localparam POF = 2;
    localparam PIF = 3;
    localparam MULT_WIDTH = 16;

    reg clk, rst_n;
    reg start;
    reg tile_valid;
    reg is_dfconv;

    reg [15:0] rows, cols, in_ch, out_ch;
    reg [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat;

    wire busy, done;

    integer error_count;
    integer i;

    controller #(
        .NUM_CORES(NUM_CORES),
        .POF(POF),
        .PIF(PIF),
        .MULT_WIDTH(MULT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .tile_valid(tile_valid),
        .is_dfconv(is_dfconv),
        .rows(rows),
        .cols(cols),
        .in_ch(in_ch),
        .out_ch(out_ch),
        .assigned_mults_flat(assigned_mults_flat),
        .start(start),
        .busy(busy),
        .done(done)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        tile_valid = 0;
        is_dfconv = 0;
        rows = 4; cols = 4; in_ch = 16; out_ch = 16;
        assigned_mults_flat = 64;
        error_count = 0;

        #20 rst_n = 1;

        // Start controller
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        // Issue SFTM tiles
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            tile_valid = 1;
            is_dfconv = 0;
        end
        tile_valid = 0;

        // Issue DFConv tiles
        for (i = 0; i < 2; i = i + 1) begin
            @(posedge clk);
            tile_valid = 1;
            is_dfconv = 1;
        end
        tile_valid = 0;

        // Wait for completion
        while (!done)
            @(posedge clk);

        if (!done) begin
            $display("ERROR: controller did not complete");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: controller works as intended");
        else
            $display("FAIL: controller has %0d errors", error_count);

        $finish;
    end

endmodule
