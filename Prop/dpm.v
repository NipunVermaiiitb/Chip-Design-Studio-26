// dpm.v
// Simplified DPM: consumes FIFO data and models deformable conv processing
// For each group it pops rows from FIFO.

`timescale 1ns/1ps
module dpm #(
    parameter DATA_W = 16,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    input wire [DATA_W-1:0] fifo_data,
    input wire fifo_data_valid,
    output reg fifo_pop,
    input wire bypass_mode
);

// States
typedef enum reg [1:0] {IDLE=0, READ=1, PROCESS=2} state_t;
state_t state;
reg [3:0] cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        fifo_pop <= 0;
        cnt <= 0;
    end else begin
        case (state)
            IDLE: begin
                fifo_pop <= 0;
                if (start) begin
                    state <= READ;
                    cnt <= 0;
                end
            end
            READ: begin
                if (fifo_data_valid) begin
                    // consume
                    fifo_pop <= 1;
                    cnt <= cnt + 1;
                    // in real DPM, use fifo_data + reference pixels to compute Fbar
                    if (cnt == (GROUP_ROWS-1)) begin
                        state <= PROCESS;
                        fifo_pop <= 0;
                    end
                end else begin
                    fifo_pop <= 0;
                end
            end
            PROCESS: begin
                // model compute latency
                fifo_pop <= 0;
                state <= IDLE;
            end
        endcase
    end
end

endmodule
