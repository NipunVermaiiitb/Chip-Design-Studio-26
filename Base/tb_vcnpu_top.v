`timescale 1ns/1ps

module tb_vcnpu_top;

    localparam NUM_CORES = 2;
    localparam POF = 2;
    localparam PIF = 3;
    localparam MULT_WIDTH = 16;
    localparam WIDTH = 16;

    reg clk, rst_n;
    reg start;
    reg [WIDTH-1:0] frame_H, frame_W;
    reg [WIDTH-1:0] tile_rows, tile_cols_max;
    reg is_dfconv;

    reg [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat;

    wire busy, done;

    integer error_count;
    integer cycles;

    vcnpu_top #(
        .NUM_CORES(NUM_CORES),
        .POF(POF),
        .PIF(PIF),
        .MULT_WIDTH(MULT_WIDTH),
        .WIDTH(WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .frame_H(frame_H),
        .frame_W(frame_W),
        .tile_rows(tile_rows),
        .tile_cols_max(tile_cols_max),
        .is_dfconv(is_dfconv),
        .assigned_mults_flat(assigned_mults_flat),
        .busy(busy),
        .done(done)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        error_count = 0;
        cycles = 0;

        frame_H = 8;
        frame_W = 8;
        tile_rows = 4;
        tile_cols_max = 4;
        is_dfconv = 0;

        // Simple uniform SCU load
        assigned_mults_flat = { (POF*PIF){16'd16} };

        #20 rst_n = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        while (!done) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 5000) begin
                $display("ERROR: timeout");
                error_count = error_count + 1;
                break;
            end
        end

        if (!done) begin
            $display("ERROR: did not complete frame");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: vcnpu_top end-to-end works as intended");
        else
            $display("FAIL: vcnpu_top has %0d errors", error_count);

        $finish;
    end

endmodule
