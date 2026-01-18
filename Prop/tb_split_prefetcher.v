`timescale 1ns/1ps

module tb_split_prefetcher;

    reg clk, rst_n;
    reg req_valid;
    reg [31:0] req_base;
    reg [31:0] req_len;
    reg [15:0] req_gid;

    wire dma_issue_valid;
    wire [31:0] dma_issue_base;
    wire [31:0] dma_issue_len;
    reg dma_issue_ready;

    reg dma_done_valid;
    reg [7:0] dma_done_tag;

    wire tile_ready_valid;
    wire [15:0] tile_ready_gid;

    integer error_count;

    split_prefetcher dut (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(req_valid),
        .req_base(req_base),
        .req_len(req_len),
        .req_gid(req_gid),
        .dma_issue_valid(dma_issue_valid),
        .dma_issue_base(dma_issue_base),
        .dma_issue_len(dma_issue_len),
        .dma_issue_ready(dma_issue_ready),
        .dma_done_valid(dma_done_valid),
        .dma_done_tag(dma_done_tag),
        .tile_ready_valid(tile_ready_valid),
        .tile_ready_gid(tile_ready_gid)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        req_valid = 0;
        dma_issue_ready = 1;
        dma_done_valid = 0;
        error_count = 0;

        #20 rst_n = 1;

        // Issue request
        @(posedge clk);
        req_valid = 1;
        req_base = 32'h1000;
        req_len  = 256;
        req_gid  = 1;
        @(posedge clk);
        req_valid = 0;

        // Check DMA issued
        @(posedge clk);
        if (!dma_issue_valid) begin
            $display("ERROR: DMA not issued");
            error_count = error_count + 1;
        end

        // Complete DMA
        @(posedge clk);
        dma_done_valid = 1;
        dma_done_tag   = 0;
        @(posedge clk);
        dma_done_valid = 0;

        // Check tile ready
        if (!tile_ready_valid || tile_ready_gid != 1) begin
            $display("ERROR: tile not marked ready");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: split_prefetcher works as intended");
        else
            $display("FAIL: split_prefetcher has %0d errors", error_count);

        $finish;
    end

endmodule
