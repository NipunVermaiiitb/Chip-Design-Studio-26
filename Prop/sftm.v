// sftm.v
// Top-level SFTM: wires PreTA -> SCA -> PosTA -> QMU skeleton
// Produces group_data per GROUP_ROWS rows and asserts group_done.

`timescale 1ns/1ps
module sftm #(
    parameter DATA_W = 16,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    // outputs
    output reg group_valid,
    output reg group_done,
    output reg [DATA_W-1:0] group_data,
    output reg group_data_valid,
    input wire bypass_mode
);

// Very simplified pipeline: produce pseudo-data when start asserted.
reg [3:0] row_cnt;
reg active;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        group_valid <= 0;
        group_done <= 0;
        group_data <= 0;
        group_data_valid <= 0;
        row_cnt <= 0;
        active <= 0;
    end else begin
        group_done <= 1'b0;
        group_data_valid <= 1'b0;
        if (start && !active) begin
            active <= 1'b1;
            row_cnt <= 0;
            group_valid <= 1'b1;
        end
        if (active) begin
            // produce one word per cycle for group rows
            group_data <= {DATA_W{1'b0}} ^ row_cnt; // placeholder data
            group_data_valid <= 1'b1;
            row_cnt <= row_cnt + 1;
            if (row_cnt == (GROUP_ROWS-1)) begin
                group_done <= 1'b1;
                active <= 0;
                group_valid <= 1'b0;
            end
        end
    end
end

endmodule
