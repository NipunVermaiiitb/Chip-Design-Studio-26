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
// Paper-SCU path (incremental migration)
//
// The reference paper SCU computes sparse element-wise multiplications in the
// transform domain using (weights,indexes) lists and gathers activations from a
// 36-entry tile. It outputs 3 banks of 16 outputs.
//
// This repository's SFTM currently expects a single transform tile output
// u_out[N_ROWS][N_COLS]. To move toward the paper architecture without breaking
// the rest of the pipeline, we use the paper SCU for the 4x4 conv case
// (IN_SIZE==16) and map OC0[0..15] back into u_out[4][4].
//
// For other sizes (e.g., 6x6 deconv), we fall back to the existing sparse list
// scheduler below.
//==============================================================================

localparam integer IN_SIZE  = N_ROWS * N_COLS;
localparam integer IDX_BITS = (IN_SIZE <= 1) ? 1 : $clog2(IN_SIZE);

generate
if (IN_SIZE == 16) begin : GEN_PAPER_SCU

    // Flattened 36-entry activation tile expected by the paper SCU
    wire signed [DATA_W-1:0] input_tile36 [0:35];
    genvar fa;
    for (fa = 0; fa < 36; fa = fa + 1) begin : FLAT_ACT
        if (fa < 16) begin
            assign input_tile36[fa] = y_in[fa[3:2]][fa[1:0]];
        end else begin
            assign input_tile36[fa] = '0;
        end
    end

    // Weights/indices lists for SCU
    // Migration choice: represent dense 4x4 element-wise multiply by phasing
    // 6 coefficients per cycle (k=0..5), over 3 cycles (ceil(16/6)=3).
    // This preserves correctness for the current dense weight_data interface.
    localparam int PHASES = 3;
    reg [1:0] phase;
    reg running;

    // SCU inputs
    reg signed [DATA_W-1:0] weights18 [0:17];
    reg [5:0] indexes18 [0:17];
    reg scu_en, scu_clear;

    wire signed [DATA_W-1:0] OC0 [0:15];
    wire signed [DATA_W-1:0] OC1 [0:15];
    wire signed [DATA_W-1:0] OC2 [0:15];

    integer wi;
    always @(*) begin
        // default all zeros
        for (wi = 0; wi < 18; wi = wi + 1) begin
            weights18[wi] = '0;
            indexes18[wi] = '0;
        end

        // Fill only first 6 entries for OC0 bank this cycle.
        // Map phase to coefficient indices:
        // phase 0: idx 0..5, phase 1: 6..11, phase 2: 12..15 (and 16/17 unused)
        for (wi = 0; wi < 6; wi = wi + 1) begin
            int coeff_idx;
            coeff_idx = (phase * 6) + wi;
            if (coeff_idx < 16) begin
                indexes18[wi] = coeff_idx[5:0];
                // Flatten weight_data row-major
                weights18[wi] = weight_data[coeff_idx[3:2]][coeff_idx[1:0]];
            end
        end
    end

    scu_paper #(
        .A_bits(DATA_W),
        .W_bits(DATA_W),
        .I_bits(6),
        .ACC_bits(ACC_W)
    ) u_scu_paper (
        .clk(clk),
        .rst_n(rst_n),
        .mode(1'b1),
        .en(scu_en),
        .clear(scu_clear),
        .weights(weights18),
        .input_tile(input_tile36),
        .indexes(indexes18),
        .OC0(OC0),
        .OC1(OC1),
        .OC2(OC2)
    );

    integer orow, ocol;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_out <= 1'b0;
            running <= 1'b0;
            phase <= 0;
            scu_en <= 1'b0;
            scu_clear <= 1'b0;
            for (orow = 0; orow < N_ROWS; orow = orow + 1)
                for (ocol = 0; ocol < N_COLS; ocol = ocol + 1)
                    u_out[orow][ocol] <= '0;
        end else begin
            valid_out <= 1'b0;
            scu_en <= 1'b0;
            scu_clear <= 1'b0;

            if (valid_in && !running) begin
                // start new tile
                running <= 1'b1;
                phase <= 0;
                scu_clear <= 1'b1;
            end else if (running) begin
                // run one SCU update per phase
                scu_en <= 1'b1;

                if (phase == (PHASES-1)) begin
                    // done this tile: capture OC0 into u_out
                    for (orow = 0; orow < 4; orow = orow + 1)
                        for (ocol = 0; ocol < 4; ocol = ocol + 1)
                            u_out[orow][ocol] <= {{(ACC_W-DATA_W){OC0[{orow[1:0], ocol[1:0]}][DATA_W-1]}}, OC0[{orow[1:0], ocol[1:0]}]};

                    valid_out <= 1'b1;
                    running <= 1'b0;
                end else begin
                    phase <= phase + 1'b1;
                end
            end
        end
    end

end else begin : GEN_FALLBACK_SCHED

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

end
endgenerate

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
