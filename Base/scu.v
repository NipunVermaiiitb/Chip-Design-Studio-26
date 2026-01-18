//====================================================
// SCU: Streaming Compute Unit
//====================================================
// - Computes ceil(assigned_mults / SCU_MULTIPLIERS)
// - Runs for that many cycles
// - Asserts done when finished
//====================================================

module scu #(
    parameter integer SCU_MULTIPLIERS = 18,
    parameter integer MULT_WIDTH = 32
)(
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   start,
    input  wire [MULT_WIDTH-1:0]  assigned_mults,

    output reg                    busy,
    output reg                    done,
    output reg [MULT_WIDTH-1:0]   cycles_used
);

    reg [MULT_WIDTH-1:0] cycles_remaining;

    // ceiling division function
    function [MULT_WIDTH-1:0] ceil_div;
        input [MULT_WIDTH-1:0] num;
        input [MULT_WIDTH-1:0] den;
        begin
            ceil_div = (num + den - 1) / den;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy             <= 1'b0;
            done             <= 1'b0;
            cycles_remaining <= {MULT_WIDTH{1'b0}};
            cycles_used      <= {MULT_WIDTH{1'b0}};
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                cycles_used      <= ceil_div(assigned_mults, SCU_MULTIPLIERS);
                cycles_remaining <= ceil_div(assigned_mults, SCU_MULTIPLIERS);
                busy             <= (assigned_mults != 0);
                if (assigned_mults == 0) begin
                    done <= 1'b1;
                end
            end
            else if (busy) begin
                if (cycles_remaining > 1) begin
                    cycles_remaining <= cycles_remaining - 1;
                end else begin
                    cycles_remaining <= 0;
                    busy             <= 1'b0;
                    done             <= 1'b1;
                end
            end
        end
    end

endmodule
