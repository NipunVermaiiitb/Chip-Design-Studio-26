// split_prefetcher.v
// Issues DRAM read requests for the reference frame region corresponding to a group
// This is a simplified address generator; integrate with your frame tiler.

`timescale 1ns/1ps
module split_prefetcher #(
    parameter ADDR_WIDTH = 32
)(
    input  wire clk,
    input  wire rst_n,
    input  wire group_done,
    output reg  issue_req,
    output reg  [ADDR_WIDTH-1:0] addr,
    output reg  [15:0] len,    // length in rows or words
    input  wire dram_ack
);

reg pending;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        issue_req <= 0;
        addr <= 0;
        len <= 0;
        pending <= 0;
    end else begin
        if (group_done && !pending) begin
            // generate an example address (in real integration, compute by group index)
            addr <= 32'h1000_0000; // placeholder
            len  <= 16'd4;         // prefetch 4 rows (group size)
            issue_req <= 1'b1;
            pending <= 1'b1;
        end else if (issue_req && dram_ack) begin
            issue_req <= 1'b0;
            pending <= 1'b0;
        end
    end
end

endmodule
