// group_sync_fifo.v
// Multi-group FIFO that buffers transform-domain groups from SFTM to DPM.
// This models a conservative multi-banked SRAM with group-level push/pop semantics.

`timescale 1ns/1ps
module group_sync_fifo #(
    parameter DATA_W = 16,
    parameter GROUP_ROWS = 4,       // rows per group
    parameter DEPTH_GROUPS = 2      // number of groups of storage
)(
    input  wire clk,
    input  wire rst_n,
    // write interface (SFTM)
    input  wire wr_en,
    input  wire [DATA_W-1:0] wr_data,
    input  wire wr_group_valid,
    input  wire group_done,         // group-level done
    // read interface (DPM)
    input  wire rd_en,
    output reg  [DATA_W-1:0] rd_data,
    output reg  rd_data_valid,
    // status
    output wire full,
    output wire empty,
    // credit interface
    input  wire credit_available,
    input  wire bypass_mode,
    output reg error
);

localparam TOTAL_ROWS = GROUP_ROWS * DEPTH_GROUPS;
localparam ADDR_W = $clog2(TOTAL_ROWS);

// Physical memory
reg [DATA_W-1:0] mem [0:TOTAL_ROWS-1];
reg [ADDR_W-1:0] wptr;
reg [ADDR_W-1:0] rptr;
reg [ADDR_W:0]   count; // up to TOTAL_ROWS

assign full  = (count == TOTAL_ROWS);
assign empty = (count == 0);

integer i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wptr <= 0;
        rptr <= 0;
        count <= 0;
        rd_data <= 0;
        rd_data_valid <= 0;
        error <= 0;
        for (i=0;i<TOTAL_ROWS;i=i+1) mem[i] <= {DATA_W{1'b0}};
    end else begin
        // write path
        if (wr_en) begin
            if (full && !bypass_mode) begin
                error <= 1'b1; // overflow
            end else begin
                mem[wptr] <= wr_data;
                wptr <= wptr + 1;
                if (count < TOTAL_ROWS) count <= count + 1;
            end
        end
        // read path
        if (rd_en) begin
            if (empty) begin
                rd_data_valid <= 1'b0;
                // underflow flagged to error
                error <= 1'b1;
            end else begin
                rd_data <= mem[rptr];
                rptr <= rptr + 1;
                rd_data_valid <= 1'b1;
                if (count > 0) count <= count - 1;
            end
        end else begin
            rd_data_valid <= 1'b0;
        end
    end
end

endmodule
