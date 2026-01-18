`timescale 1ns/1ps

module tb_scu;

    localparam SCU_MULTIPLIERS = 18;
    localparam MULT_WIDTH      = 32;

    reg clk;
    reg rst_n;
    reg start;
    reg [MULT_WIDTH-1:0] assigned_mults;

    wire busy;
    wire done;
    wire [MULT_WIDTH-1:0] cycles_used;

    integer expected_cycles;
    integer error_count;

    // DUT
    scu #(
        .SCU_MULTIPLIERS(SCU_MULTIPLIERS),
        .MULT_WIDTH(MULT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .assigned_mults(assigned_mults),
        .busy(busy),
        .done(done),
        .cycles_used(cycles_used)
    );

    // clock
    always #5 clk = ~clk;

    // ceiling division (TB golden model)
    function integer ceil_div;
        input integer num;
        input integer den;
        begin
            ceil_div = (num + den - 1) / den;
        end
    endfunction

    task run_test;
        input integer macs;
        integer cycle_count;
        begin
            assigned_mults = macs;
            expected_cycles = ceil_div(macs, SCU_MULTIPLIERS);
            cycle_count = 0;

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            while (!done) begin
                @(posedge clk);
                cycle_count = cycle_count + 1;
            end

            if (cycle_count !== expected_cycles) begin
                $display("ERROR: MACs=%0d Expected cycles=%0d Got=%0d",
                         macs, expected_cycles, cycle_count);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        assigned_mults = 0;
        error_count = 0;

        #20;
        rst_n = 1;

        // Test cases
        run_test(0);
        run_test(1);
        run_test(18);
        run_test(19);
        run_test(36);
        run_test(100);
        run_test(1024);

        if (error_count == 0)
            $display("PASS: SCU works as intended");
        else
            $display("FAIL: SCU has %0d errors", error_count);

        $finish;
    end

endmodule
