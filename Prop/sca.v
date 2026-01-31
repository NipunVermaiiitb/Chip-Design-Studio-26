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

//==============================================================================
// Sparse compute core (paper-style): Nonzero list + index-driven selection +
// psum scatter/accumulation scheduling.
//
// We interpret the incoming memories as:
// - weight_data[r][c] => H[k] (nonzero weight list entry)
// - index_data[r][c]  => S[k] packed (enable/mask + dest index + src index)
//
// Where k is the flattened index: k = r*N_COLS + c.
//
// Packed index format (MSB..LSB):
//   enable | dest[IDX_BITS-1:0] | src[IDX_BITS-1:0]
//
// This matches Fig. 6's concept: select Yd[src] with S, multiply by H,
// then scatter into accumulator for U[dest].
//==============================================================================

localparam integer IN_SIZE  = N_ROWS * N_COLS;
localparam integer IDX_BITS = (IN_SIZE <= 1) ? 1 : $clog2(IN_SIZE);

// Internal regfiles
reg signed [DATA_W-1:0] y_reg_flat [0:IN_SIZE-1];
reg signed [DATA_W-1:0] h_reg_flat [0:IN_SIZE-1];
reg [INDEX_ADDR_W-1:0]  s_reg_flat [0:IN_SIZE-1];

// Accumulators (U destinations)
reg signed [ACC_W-1:0] psum [0:IN_SIZE-1];

// Scheduling state
reg busy;
reg [$clog2(IN_SIZE+1)-1:0] k;

// Decode current sparse entry
wire entry_en;
wire [IDX_BITS-1:0] entry_src;
wire [IDX_BITS-1:0] entry_dst;

assign entry_en  = s_reg_flat[k][INDEX_ADDR_W-1];
assign entry_src = s_reg_flat[k][IDX_BITS-1:0];
assign entry_dst = s_reg_flat[k][(2*IDX_BITS)-1:IDX_BITS];

wire signed [DATA_W-1:0] h_cur = h_reg_flat[k];
wire signed [DATA_W-1:0] y_cur = y_reg_flat[entry_src];

wire do_mac = busy && entry_en && (h_cur != 0);
wire signed [ACC_W-1:0] prod = $signed(y_cur) * $signed(h_cur);

integer ri, rj;
integer ai;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        valid_out <= 1'b0;
        busy <= 1'b0;
        k <= 0;
        for (ai = 0; ai < IN_SIZE; ai = ai + 1) begin
            y_reg_flat[ai] <= 0;
            h_reg_flat[ai] <= 0;
            s_reg_flat[ai] <= 0;
            psum[ai] <= 0;
        end
        for (ri = 0; ri < N_ROWS; ri = ri + 1)
            for (rj = 0; rj < N_COLS; rj = rj + 1)
                u_out[ri][rj] <= 0;
    end else begin
        valid_out <= 1'b0;

        // Latch a new tile and initialize accumulators
        if (valid_in && !busy) begin
            // Flatten inputs and sparse lists
            for (ri = 0; ri < N_ROWS; ri = ri + 1) begin
                for (rj = 0; rj < N_COLS; rj = rj + 1) begin
                    y_reg_flat[ri*N_COLS + rj] <= y_in[ri][rj];
                    h_reg_flat[ri*N_COLS + rj] <= weight_data[ri][rj];
                    s_reg_flat[ri*N_COLS + rj] <= index_data[ri][rj];
                end
            end
            for (ai = 0; ai < IN_SIZE; ai = ai + 1) begin
                psum[ai] <= 0;
            end
            k <= 0;
            busy <= 1'b1;
        end

        // One sparse entry per cycle (accumulation scheduling)
        if (busy) begin
            if (do_mac) begin
                psum[entry_dst] <= psum[entry_dst] + prod;
            end

            // advance
            if (k == IN_SIZE-1) begin
                // write out accumulated results back into 2D patch
                for (ri = 0; ri < N_ROWS; ri = ri + 1) begin
                    for (rj = 0; rj < N_COLS; rj = rj + 1) begin
                        u_out[ri][rj] <= psum[ri*N_COLS + rj];
                    end
                end
                valid_out <= 1'b1;
                busy <= 1'b0;
            end else begin
                k <= k + 1'b1;
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
