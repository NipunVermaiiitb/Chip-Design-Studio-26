`timescale 1ns/1ps

module tb_dfconv;

    localparam WIDTH = 16;
    localparam ACC_WIDTH = 32;
    localparam DFCONV_INTERP_COST_PER_SAMPLE = 2;
    localparam DFCONV_PE_COUNT = 64;

    reg clk, rst_n;
    reg start;
    reg [WIDTH-1:0] rows, cols, in_ch, out_ch;

    wire busy, done;
    wire [ACC_WIDTH-1:0] cycles_used;

    integer error_count;
    integer exp_cycles;
    integer cycle_counter;

    dfconv #(
        .DFCONV_INTERP_COST_PER_SAMPLE(DFCONV_INTERP_COST_PER_SAMPLE),
        .DFCONV_PE_COUNT(DFCONV_PE_COUNT),
        .WIDTH(WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .rows(rows),
        .cols(cols),
        .in_ch(in_ch),
        .out_ch(out_ch),
        .busy(busy),
        .done(done),
        .cycles_used(cycles_used)
    );

    always #5 clk = ~clk;

    function integer ceil_div;
        input integer a, b;
        begin ceil_div = (a + b - 1) / b; end
    endfunction

    task run_test;
        input integer r, c, ic, oc;
        integer out_pixels, interp, macs, mac_cycles;
        begin
            rows   = r;
            cols   = c;
            in_ch  = ic;
            out_ch = oc;

            out_pixels = r * c;
            interp = out_pixels * DFCONV_INTERP_COST_PER_SAMPLE;
            macs   = (out_pixels * oc * 9 * ic) / 4;
            mac_cycles = ceil_div(macs, DFCONV_PE_COUNT);
            exp_cycles = interp + mac_cycles;

            @(posedge clk);
            start = 1;
            @(posedge clk);
            start = 0;

            cycle_counter = 0;
            while (!done) begin
                @(posedge clk);
                cycle_counter = cycle_counter + 1;
            end

            if (cycle_counter !== exp_cycles) begin
                $display("ERROR: rows=%0d cols=%0d in=%0d out=%0d exp=%0d got=%0d",
                         r, c, ic, oc, exp_cycles, cycle_counter);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        rows = 0;
        cols = 0;
        in_ch = 0;
        out_ch = 0;
        error_count = 0;

        #20 rst_n = 1;

        run_test(4, 4, 36, 36);
        run_test(8, 8, 36, 36);
        run_test(4, 16, 36, 36);
        run_test(1, 1, 1, 1);

        if (error_count == 0)
            $display("PASS: dfconv works as intended");
        else
            $display("FAIL: dfconv has %0d errors", error_count);

        $finish;
    end

endmodule
