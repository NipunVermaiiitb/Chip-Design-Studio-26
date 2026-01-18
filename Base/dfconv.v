//====================================================
// DfConv Module (Analytic Cycle Model)
//====================================================

module dfconv #(
    parameter integer DFCONV_INTERP_COST_PER_SAMPLE = 2,
    parameter integer DFCONV_PE_COUNT = 64,
    parameter integer WIDTH = 16,
    parameter integer ACC_WIDTH = 32
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,
    input  wire [WIDTH-1:0] rows,
    input  wire [WIDTH-1:0] cols,
    input  wire [WIDTH-1:0] in_ch,
    input  wire [WIDTH-1:0] out_ch,

    output reg  busy,
    output reg  done,
    output reg  [ACC_WIDTH-1:0] cycles_used
);

    reg [ACC_WIDTH-1:0] cycles_remaining;

    // ceiling division
    function [ACC_WIDTH-1:0] ceil_div;
        input [ACC_WIDTH-1:0] a, b;
        begin
            ceil_div = (a + b - 1) / b;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy             <= 1'b0;
            done             <= 1'b0;
            cycles_used      <= 0;
            cycles_remaining <= 0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                // compute analytic cycles
                // out_pixels = rows * cols
                // interp = out_pixels * DFCONV_INTERP_COST_PER_SAMPLE
                // macs = out_pixels * out_ch * 9 * in_ch / 4
                // total = interp + ceil(macs / DFCONV_PE_COUNT)

                reg [ACC_WIDTH-1:0] out_pixels;
                reg [ACC_WIDTH-1:0] interp;
                reg [ACC_WIDTH-1:0] macs;
                reg [ACC_WIDTH-1:0] mac_cycles;

                out_pixels = rows * cols;
                interp     = out_pixels * DFCONV_INTERP_COST_PER_SAMPLE;
                macs       = (out_pixels * out_ch * 9 * in_ch) >> 2;
                mac_cycles = ceil_div(macs, DFCONV_PE_COUNT);

                cycles_used      <= interp + mac_cycles;
                cycles_remaining <= interp + mac_cycles;
                busy             <= (interp + mac_cycles != 0);
                if ((interp + mac_cycles) == 0)
                    done <= 1'b1;
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
