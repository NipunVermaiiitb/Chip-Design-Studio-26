`timescale 1ns/1ps

module tb_consumer_dpm;

    localparam FRAME_COLS = 64;
    localparam BASE_PERIOD = 20;
    localparam JITTER = 0;

    reg clk, rst_n, start;
    reg consume_start;
    reg [15:0] tile_columns;

    wire ready_to_consume;
    wire [31:0] consumed_count;

    integer error_count;
    integer consume_events;

    consumer_dpm #(
        .FRAME_COLS(FRAME_COLS),
        .BASE_PERIOD(BASE_PERIOD),
        .JITTER(JITTER)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .tile_columns(tile_columns),
        .consume_start(consume_start),
        .ready_to_consume(ready_to_consume),
        .consumed_count(consumed_count)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        consume_start = 0;
        tile_columns = 16;
        error_count = 0;
        consume_events = 0;

        #20 rst_n = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        repeat (200) begin
            @(posedge clk);
            if (ready_to_consume) begin
                consume_start = 1;
                consume_events = consume_events + 1;
            end else begin
                consume_start = 0;
            end
        end
        consume_start = 0;

        if (consumed_count !== consume_events) begin
            $display("ERROR: consumed_count=%0d events=%0d",
                     consumed_count, consume_events);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: consumer_dpm works as intended");
        else
            $display("FAIL: consumer_dpm has %0d errors", error_count);

        $finish;
    end

endmodule
