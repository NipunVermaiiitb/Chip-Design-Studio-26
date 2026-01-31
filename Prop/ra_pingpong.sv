// ra_pingpong.sv
// Lightweight RA ping-pong buffers for a prefetched reference tile.
// This keeps the "paper-style" RA0/RA1 structure while matching the existing
// VCNPU integration that streams ref_data in via DRAM.

`timescale 1ns/1ps

module ra_pingpong #(
    parameter int DATA_W = 16,
    parameter int W = 16,
    parameter int H = 16
)(
    input  logic clk,
    input  logic rst_n,

    input  logic start_fill,
    input  logic wr_en,
    input  logic [$clog2(W*H)-1:0] wr_addr,
    input  logic [DATA_W-1:0] wr_data,

    output logic rd_bank_sel, // current READ bank (opposite of write bank)
    input  logic [$clog2(W*H)-1:0] rd_addr0,
    input  logic [$clog2(W*H)-1:0] rd_addr1,
    input  logic [$clog2(W*H)-1:0] rd_addr2,
    input  logic [$clog2(W*H)-1:0] rd_addr3,
    output logic [DATA_W-1:0] rd_data0,
    output logic [DATA_W-1:0] rd_data1,
    output logic [DATA_W-1:0] rd_data2,
    output logic [DATA_W-1:0] rd_data3
);

    logic [DATA_W-1:0] bank0 [0:W*H-1];
    logic [DATA_W-1:0] bank1 [0:W*H-1];

    logic cur_wr_bank;

    assign rd_bank_sel = ~cur_wr_bank;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_wr_bank <= 1'b0;
        end else if (start_fill) begin
            cur_wr_bank <= ~cur_wr_bank;
        end else if (wr_en) begin
            if (!cur_wr_bank) bank0[wr_addr] <= wr_data;
            else bank1[wr_addr] <= wr_data;
        end
    end

    always_comb begin
        if (!rd_bank_sel) begin
            rd_data0 = bank0[rd_addr0];
            rd_data1 = bank0[rd_addr1];
            rd_data2 = bank0[rd_addr2];
            rd_data3 = bank0[rd_addr3];
        end else begin
            rd_data0 = bank1[rd_addr0];
            rd_data1 = bank1[rd_addr1];
            rd_data2 = bank1[rd_addr2];
            rd_data3 = bank1[rd_addr3];
        end
    end

endmodule
