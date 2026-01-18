`timescale 1ns/1ps

module tb_dma_engine;

    localparam DRAM_LATENCY = 10;
    localparam BW_BYTES_PER_CYCLE = 16;
    localparam MAX_OUTSTANDING = 4;

    reg clk, rst_n;
    reg issue_valid;
    reg [31:0] issue_base_addr;
    reg [31:0] issue_length;

    wire issue_ready;
    wire [7:0] issue_tag;
    wire done_valid;
    wire [7:0] done_tag;
    wire [8:0] outstanding_count;

    integer cycle;
    integer error_count;
    integer expected_done_cycle [0:3];
    integer seen_done [0:3];

    dma_engine #(
        .DRAM_LATENCY(DRAM_LATENCY),
        .BW_BYTES_PER_CYCLE(BW_BYTES_PER_CYCLE),
        .MAX_OUTSTANDING(MAX_OUTSTANDING)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(issue_valid),
        .issue_base_addr(issue_base_addr),
        .issue_length(issue_length),
        .issue_ready(issue_ready),
        .issue_tag(issue_tag),
        .done_valid(done_valid),
        .done_tag(done_tag),
        .outstanding_count(outstanding_count)
    );

    always #5 clk = ~clk;

    function integer ceil_div;
        input integer a, b;
        begin ceil_div = (a + b - 1) / b; end
    endfunction

    initial begin
        clk = 0;
        rst_n = 0;
        issue_valid = 0;
        issue_base_addr = 0;
        issue_length = 0;
        cycle = 0;
        error_count = 0;

        #20 rst_n = 1;

        // Issue 3 requests
        issue_length = 64; // transfer cycles = ceil(64/16)=4
        expected_done_cycle[0] = DRAM_LATENCY + 4;

        @(posedge clk);
        issue_valid = 1;
        @(posedge clk);
        issue_valid = 0;

        issue_length = 32; // ceil(32/16)=2
        expected_done_cycle[1] = DRAM_LATENCY + 2;

        @(posedge clk);
        issue_valid = 1;
        @(posedge clk);
        issue_valid = 0;

        issue_length = 16; // ceil(16/16)=1
        expected_done_cycle[2] = DRAM_LATENCY + 1;

        @(posedge clk);
        issue_valid = 1;
        @(posedge clk);
        issue_valid = 0;

        // Track completions
        for (cycle = 1; cycle < 50; cycle = cycle + 1) begin
            @(posedge clk);
            if (done_valid) begin
                seen_done[done_tag-1] = cycle;
            end
        end

        // Check results
        if (seen_done[0] !== expected_done_cycle[0]) begin
            $display("ERROR: req0 done @%0d exp %0d", seen_done[0], expected_done_cycle[0]);
            error_count = error_count + 1;
        end
        if (seen_done[1] !== expected_done_cycle[1]) begin
            $display("ERROR: req1 done @%0d exp %0d", seen_done[1], expected_done_cycle[1]);
            error_count = error_count + 1;
        end
        if (seen_done[2] !== expected_done_cycle[2]) begin
            $display("ERROR: req2 done @%0d exp %0d", seen_done[2], expected_done_cycle[2]);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: dma_engine works as intended");
        else
            $display("FAIL: dma_engine has %0d errors", error_count);

        $finish;
    end

endmodule
