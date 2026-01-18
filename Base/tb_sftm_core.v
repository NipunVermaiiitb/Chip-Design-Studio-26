`timescale 1ns/1ps

module tb_sftm_core;

    localparam POF = 2;
    localparam PIF = 3;
    localparam MULT_WIDTH = 16;
    localparam SCU_MULTIPLIERS = 4;

    reg clk, rst_n;
    reg start, job_valid;
    reg [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat;

    wire busy, job_done;

    integer error_count;
    integer max_cycles, expected_cycles;
    integer i;

    sftm_core #(
        .POF(POF),
        .PIF(PIF),
        .SCU_MULTIPLIERS(SCU_MULTIPLIERS),
        .PRETU_LATENCY(2),
        .POSTTU_LATENCY(2),
        .SCU_PIPELINE_LATENCY(1),
        .MULT_WIDTH(MULT_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .job_valid(job_valid),
        .assigned_mults_flat(assigned_mults_flat),
        .start(start),
        .busy(busy),
        .job_done(job_done)
    );

    always #5 clk = ~clk;

    function integer ceil_div;
        input integer a, b;
        begin ceil_div = (a + b - 1) / b; end
    endfunction

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        job_valid = 0;
        assigned_mults_flat = 0;
        error_count = 0;

        #20 rst_n = 1;

        // Assign different loads per SCU
        max_cycles = 0;
        for (i = 0; i < POF*PIF; i = i + 1) begin
            assigned_mults_flat[i*MULT_WIDTH +: MULT_WIDTH] = i * 3 + 1;
            if (ceil_div(i*3+1, SCU_MULTIPLIERS) > max_cycles)
                max_cycles = ceil_div(i*3+1, SCU_MULTIPLIERS);
        end

        expected_cycles = 2 + max_cycles + 1 + 2;

        @(posedge clk);
        job_valid = 1;
        @(posedge clk);
        job_valid = 0;

        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;

        i = 0;
        while (!job_done) begin
            @(posedge clk);
            i = i + 1;
        end

        if (i !== expected_cycles) begin
            $display("ERROR: expected %0d cycles, got %0d",
                     expected_cycles, i);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: sftm_core works as intended");
        else
            $display("FAIL: sftm_core has %0d errors", error_count);

        $finish;
    end

endmodule
