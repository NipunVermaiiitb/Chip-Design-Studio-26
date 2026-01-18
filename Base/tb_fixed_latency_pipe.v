`timescale 1ns/1ps

module tb_fixed_latency_pipe;

    reg clk;
    reg rst_n;
    reg start;

    wire busy;
    wire done;

    integer cycle_count;
    integer error_count;

    localparam LATENCY = 4;

    fixed_latency_pipe #(
        .LATENCY(LATENCY),
        .CNT_WIDTH(8)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .busy(busy),
        .done(done)
    );

    // clock
    always #5 clk = ~clk;

    task run_test;
        integer cycles;
        begin
            cycle_count = 0;
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            while (!done) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
            end

            cycles = cycle_count;

            if (cycles !== LATENCY) begin
                $display("ERROR: Expected latency=%0d Got=%0d",
                         LATENCY, cycles);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        error_count = 0;

        #20;
        rst_n = 1;

        // Run multiple times
        run_test();
        run_test();
        run_test();

        if (error_count == 0)
            $display("PASS: Fixed Latency Pipe works as intended");
        else
            $display("FAIL: Fixed Latency Pipe has %0d errors", error_count);

        $finish;
    end

endmodule
