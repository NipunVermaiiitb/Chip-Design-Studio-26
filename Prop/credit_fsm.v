// credit_fsm.v
// Track number of valid groups in FIFO; indicates when DPM may consume.

`timescale 1ns/1ps
module credit_fsm #(
    parameter MAX_CREDITS = 2
)(
    input  wire clk,
    input  wire rst_n,
    input  wire group_produced,    // increment credit
    input  wire group_consumed,    // decrement credit
    output wire credit_available
);

reg [$clog2(MAX_CREDITS+1)-1:0] credits;

assign credit_available = (credits > 0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        credits <= 0;
    end else begin
        // simple non-overlapping update
        if (group_produced && !group_consumed) begin
            if (credits < MAX_CREDITS) credits <= credits + 1;
        end else if (!group_produced && group_consumed) begin
            if (credits > 0) credits <= credits - 1;
        end
        // if both asserted, net zero
    end
end

endmodule
