//====================================================
// DMA Engine (Cycle-Accurate Performance Model)
//====================================================

module dma_engine #(
    parameter integer DRAM_LATENCY = 800,
    parameter integer BW_BYTES_PER_CYCLE = 1024, // bytes per cycle
    parameter integer MAX_OUTSTANDING = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer LEN_WIDTH  = 32,
    parameter integer TAG_WIDTH  = 8,
    parameter integer CNT_WIDTH  = 32
)(
    input  wire clk,
    input  wire rst_n,

    // Issue interface
    input  wire issue_valid,
    input  wire [ADDR_WIDTH-1:0] issue_base_addr,
    input  wire [LEN_WIDTH-1:0]  issue_length,
    output reg  issue_ready,
    output reg  [TAG_WIDTH-1:0]  issue_tag,

    // Completion interface
    output reg  done_valid,
    output reg  [TAG_WIDTH-1:0]  done_tag,

    // Status
    output reg  [TAG_WIDTH:0]    outstanding_count
);

    // -------------------------
    // In-flight table
    // -------------------------
    reg inflight_valid [0:MAX_OUTSTANDING-1];
    reg [TAG_WIDTH-1:0] inflight_tag [0:MAX_OUTSTANDING-1];
    reg [CNT_WIDTH-1:0] inflight_cnt [0:MAX_OUTSTANDING-1];

    reg [TAG_WIDTH-1:0] next_tag;

    integer i;

    // ceiling division
    function [CNT_WIDTH-1:0] ceil_div;
        input [CNT_WIDTH-1:0] a;
        input [CNT_WIDTH-1:0] b;
        begin
            ceil_div = (a + b - 1) / b;
        end
    endfunction

    // combinational
    always @(*) begin
        issue_ready = (outstanding_count < MAX_OUTSTANDING);
    end

    // sequential
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            next_tag           <= 1;
            outstanding_count  <= 0;
            issue_tag          <= 0;
            done_valid         <= 1'b0;
            done_tag           <= 0;

            for (i = 0; i < MAX_OUTSTANDING; i = i + 1) begin
                inflight_valid[i] <= 1'b0;
                inflight_cnt[i]   <= 0;
                inflight_tag[i]   <= 0;
            end
        end else begin
            done_valid <= 1'b0;

            // -------------------------
            // Issue new request
            // -------------------------
            if (issue_valid && issue_ready) begin
                // find free slot
                for (i = 0; i < MAX_OUTSTANDING; i = i + 1) begin
                    if (!inflight_valid[i]) begin
                        inflight_valid[i] <= 1'b1;
                        inflight_tag[i]   <= next_tag;

                        // cycles = dram_latency + ceil(bytes / bw)
                        inflight_cnt[i] <= DRAM_LATENCY +
                                           ceil_div(issue_length, BW_BYTES_PER_CYCLE);

                        issue_tag <= next_tag;
                        next_tag  <= next_tag + 1'b1;
                        outstanding_count <= outstanding_count + 1'b1;
                        disable issue_loop;
                    end
                end
            end
            issue_loop: ;

            // -------------------------
            // Advance in-flight requests
            // -------------------------
            for (i = 0; i < MAX_OUTSTANDING; i = i + 1) begin
                if (inflight_valid[i]) begin
                    if (inflight_cnt[i] > 1) begin
                        inflight_cnt[i] <= inflight_cnt[i] - 1'b1;
                    end else begin
                        // complete
                        inflight_valid[i] <= 1'b0;
                        inflight_cnt[i]   <= 0;
                        done_valid        <= 1'b1;
                        done_tag          <= inflight_tag[i];
                        outstanding_count <= outstanding_count - 1'b1;
                    end
                end
            end
        end
    end

endmodule
