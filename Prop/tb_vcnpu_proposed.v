`timescale 1ns/1ps

module tb_vcnpu_proposed;

    reg clk, rst_n, start;
    wire done;

    integer error_count;
    integer cycles;

    vcnpu_proposed dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .done(done)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        cycles = 0;
        error_count = 0;

        #20 rst_n = 1;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        while (!done) begin
            @(posedge clk);
            cycles = cycles + 1;
            if (cycles > 2000) begin
                $display("ERROR: timeout");
                error_count = error_count + 1;
                break;
            end
        end

        if (!done) begin
            $display("ERROR: system did not complete");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: vcnpu_proposed end-to-end works as intended");
        else
            $display("FAIL: vcnpu_proposed has %0d errors", error_count);

        $finish;
    end

endmodule
