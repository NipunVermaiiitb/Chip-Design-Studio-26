//====================================================
// Fixed Latency Pipeline
// Used for PreTU and PostTU
//====================================================
// - On start: waits LATENCY cycles
// - Then asserts done for 1 cycle
//====================================================

module fixed_latency_pipe #(
    parameter integer LATENCY = 4,
    parameter integer CNT_WIDTH = 8
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    output reg  busy,
    output reg  done
);

    reg [CNT_WIDTH-1:0] counter;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 0;
            busy    <= 1'b0;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                if (LATENCY == 0) begin
                    done <= 1'b1;
                end else begin
                    busy    <= 1'b1;
                    counter <= LATENCY - 1;
                end
            end
            else if (busy) begin
                if (counter > 0) begin
                    counter <= counter - 1;
                end else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            end
        end
    end

endmodule
