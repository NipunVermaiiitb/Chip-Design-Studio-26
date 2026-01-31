// sbilinear.sv
`timescale 1ns/1ps

module sbilinear #(
    parameter int DATA_W = 16,
    parameter int SHW = 6
)(
    input  logic clk,
    input  logic rst_n,

    input  logic valid_in,
    input  logic signed [DATA_W-1:0] v00,
    input  logic signed [DATA_W-1:0] v01,
    input  logic signed [DATA_W-1:0] v10,
    input  logic signed [DATA_W-1:0] v11,
    input  logic [SHW-1:0] s0,
    input  logic [SHW-1:0] s1,
    input  logic [SHW-1:0] s2,
    input  logic [SHW-1:0] s3,

    output logic signed [DATA_W-1:0] out,
    output logic valid_out
);
    // 1-cycle pipeline: shift and accumulate
    logic signed [DATA_W+SHW:0] sum;
    logic signed [DATA_W+SHW:0] sum_next;

    logic [$clog2(DATA_W+1)-1:0] s0_c, s1_c, s2_c, s3_c;

    always_comb begin
        // Clamp shift to [0..DATA_W-1]
        s0_c = (s0 >= DATA_W) ? (DATA_W-1) : s0[$clog2(DATA_W+1)-1:0];
        s1_c = (s1 >= DATA_W) ? (DATA_W-1) : s1[$clog2(DATA_W+1)-1:0];
        s2_c = (s2 >= DATA_W) ? (DATA_W-1) : s2[$clog2(DATA_W+1)-1:0];
        s3_c = (s3 >= DATA_W) ? (DATA_W-1) : s3[$clog2(DATA_W+1)-1:0];
    end

    always_comb begin
        sum_next = ($signed(v00) >>> s0_c)
                 + ($signed(v01) >>> s1_c)
                 + ($signed(v10) >>> s2_c)
                 + ($signed(v11) >>> s3_c);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum <= '0;
            out <= '0;
            valid_out <= 1'b0;
        end else begin
            if (valid_in) begin
                sum <= sum_next;
                out <= sum_next[DATA_W-1:0];
                valid_out <= 1'b1;
            end else begin
                valid_out <= 1'b0;
            end
        end
    end
endmodule
