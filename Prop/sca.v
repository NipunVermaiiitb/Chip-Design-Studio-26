// sca.v
// Sparse Computing Array - implements element-wise multiplication in transform domain
// Based on VCNPU paper Figure 5 and 6
// Instantiates multiple SCU units for parallel sparse convolution processing

`timescale 1ns/1ps
module sca #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_ROWS = 4,    // Transform domain size (4x4 or 6x6)
    parameter N_COLS = 4,
    parameter N_CH = 36,     // Number of channels
    parameter WEIGHT_ADDR_W = 12,
    parameter INDEX_ADDR_W = 10
)(
    input wire clk,
    input wire rst_n,
    
    // Input from PreTA (transformed activations)
    input wire valid_in,
    input wire signed [DATA_W-1:0] y_in [0:N_ROWS-1][0:N_COLS-1],
    
    // Weight and index memory interface
    input wire signed [DATA_W-1:0] weight_data [0:N_ROWS-1][0:N_COLS-1],
    input wire [INDEX_ADDR_W-1:0] index_data [0:N_ROWS-1][0:N_COLS-1],
    output reg [WEIGHT_ADDR_W-1:0] weight_addr,
    output reg [INDEX_ADDR_W-1:0] index_addr,
    
    // Output to PosTA (transformed output)
    output reg valid_out,
    output reg signed [ACC_W-1:0] u_out [0:N_ROWS-1][0:N_COLS-1]
);

// Internal signals for SCU array
wire signed [ACC_W-1:0] scu_psum [0:N_ROWS-1][0:N_COLS-1];
wire scu_valid [0:N_ROWS-1][0:N_COLS-1];

// Pipeline registers
reg valid_d1, valid_d2;
reg signed [DATA_W-1:0] y_reg [0:N_ROWS-1][0:N_COLS-1];
reg signed [DATA_W-1:0] w_reg [0:N_ROWS-1][0:N_COLS-1];

// Generate SCU array for element-wise multiplication
genvar i, j;
generate
    for (i = 0; i < N_ROWS; i = i + 1) begin : scu_row
        for (j = 0; j < N_COLS; j = j + 1) begin : scu_col
            scu #(
                .DATA_W(DATA_W),
                .ACC_W(ACC_W)
            ) u_scu (
                .clk(clk),
                .rst_n(rst_n),
                .valid_in(valid_d1),
                .act_in(y_reg[i][j]),
                .weight_in(w_reg[i][j]),
                .psum_out(scu_psum[i][j]),
                .valid_out(scu_valid[i][j])
            );
        end
    end
endgenerate

// Pipeline stage 1: Register inputs
integer pi, pj;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_d1 <= 0;
        for (pi = 0; pi < N_ROWS; pi = pi + 1) begin
            for (pj = 0; pj < N_COLS; pj = pj + 1) begin
                y_reg[pi][pj] <= 0;
                w_reg[pi][pj] <= 0;
            end
        end
    end else begin
        valid_d1 <= valid_in;
        if (valid_in) begin
            for (pi = 0; pi < N_ROWS; pi = pi + 1) begin
                for (pj = 0; pj < N_COLS; pj = pj + 1) begin
                    y_reg[pi][pj] <= y_in[pi][pj];
                    w_reg[pi][pj] <= weight_data[pi][pj];
                end
            end
        end
    end
end

// Pipeline stage 2: Collect outputs from SCU array
integer oi, oj;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 0;
        for (oi = 0; oi < N_ROWS; oi = oi + 1) begin
            for (oj = 0; oj < N_COLS; oj = oj + 1) begin
                u_out[oi][oj] <= 0;
            end
        end
    end else begin
        valid_out <= scu_valid[0][0]; // Use first SCU valid signal
        if (scu_valid[0][0]) begin
            for (oi = 0; oi < N_ROWS; oi = oi + 1) begin
                for (oj = 0; oj < N_COLS; oj = oj + 1) begin
                    u_out[oi][oj] <= scu_psum[oi][oj];
                end
            end
        end
    end
end

// Weight/Index address generation (simplified - could be more sophisticated)
reg [WEIGHT_ADDR_W-1:0] addr_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        addr_cnt <= 0;
        weight_addr <= 0;
        index_addr <= 0;
    end else begin
        if (valid_in) begin
            weight_addr <= addr_cnt;
            index_addr <= addr_cnt[INDEX_ADDR_W-1:0];
            addr_cnt <= addr_cnt + 1;
        end
    end
end

endmodule
