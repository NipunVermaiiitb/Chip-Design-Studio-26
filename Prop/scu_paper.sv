// scu_paper.sv
// Paper-style Sparse Computing Unit (SCU)
// - 36 activation tile entries
// - 18 sparse weights + 18 indexes
// - Accumulates into 3 output-channel banks of 16 outputs (OC0/OC1/OC2)
// - mode=1: Rfconv (3 output channels); mode=0: Rfdeconv (1 output channel)
// multi-updates to the same destination address in one cycle are accumulated
// correctly using a temporary "next" accumulator image.

`timescale 1ns/1ps

module scu_paper #(
    parameter int A_bits = 12,
    parameter int W_bits = 16,
    parameter int I_bits = 6,
    parameter int ACC_bits = 32
)(
    input  logic clk,
    input  logic rst_n,       // active-low reset
    input  logic mode,        // 1 = Rfconv, 0 = Rfdeconv
    input  logic en,          // start/enable compute for this cycle
    input  logic clear,       // clear accumulators

    input  logic signed [W_bits-1:0] weights    [17:0],
    input  logic signed [A_bits-1:0] input_tile [35:0],
    input  logic        [I_bits-1:0] indexes    [17:0],

    output logic signed [A_bits-1:0] OC0 [15:0],
    output logic signed [A_bits-1:0] OC1 [15:0],
    output logic signed [A_bits-1:0] OC2 [15:0]
);

    // Activations: 36 entries always available.
    // mode=1 uses only first 16 (0..15); others forced to 0.
    logic signed [A_bits-1:0] activation [35:0];

    genvar a;
    generate
        for (a = 0; a < 36; a = a + 1) begin : ACT_ASSIGN
            assign activation[a] = (mode && (a >= 16)) ? '0 : input_tile[a];
        end
    endgenerate

    // Gather
    logic signed [A_bits-1:0] Y [17:0];

    genvar i;
    generate
        for (i = 0; i < 18; i = i + 1) begin : GATHER
            wire [I_bits-1:0] idx_conv  = {2'b00, indexes[i][3:0]};
            wire [I_bits-1:0] idx_final = mode ? idx_conv : indexes[i];
            assign Y[i] = activation[idx_final];
        end
    endgenerate

    // Multiply
    localparam int PROD_bits = A_bits + W_bits;
    logic signed [PROD_bits-1:0] partial_product [17:0];

    genvar j;
    generate
        for (j = 0; j < 18; j = j + 1) begin : MULT
            assign partial_product[j] = $signed(Y[j]) * $signed(weights[j]);
        end
    endgenerate

    // Registered accumulators: 48 entries
    logic signed [ACC_bits-1:0] accu [47:0];

    // helper function to compute destination accumulator address
    function automatic logic [5:0] accu_addr(input int k, input logic [I_bits-1:0] idx);
        begin
            if (mode) begin
                // mode=1: 3 banks of 16
                if (k < 6)       accu_addr = idx;        // 0..15  (OC0)
                else if (k < 12) accu_addr = idx + 16;   // 16..31 (OC1)
                else             accu_addr = idx + 32;   // 32..47 (OC2)
            end else begin
                // mode=0: all accumulate into first bank only
                accu_addr = idx; // 0..35 typically
            end
        end
    endfunction

    // next-state image to correctly handle multiple hits to same addr in one cycle
    logic signed [ACC_bits-1:0] accu_next [47:0];

    integer x;
    always_comb begin
        for (x = 0; x < 48; x = x + 1) begin
            accu_next[x] = accu[x];
        end

        if (clear) begin
            for (x = 0; x < 48; x = x + 1) begin
                accu_next[x] = '0;
            end
        end else if (en) begin
            for (x = 0; x < 18; x = x + 1) begin
                logic [I_bits-1:0] idx_eff;
                logic [5:0] addr;
                logic signed [ACC_bits-1:0] pp_ext;

                idx_eff = mode ? {2'b00, indexes[x][3:0]} : indexes[x];
                addr    = accu_addr(x, idx_eff);

                pp_ext = {{(ACC_bits-PROD_bits){partial_product[x][PROD_bits-1]}}, partial_product[x]};
                accu_next[addr] = accu_next[addr] + pp_ext;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (x = 0; x < 48; x = x + 1) begin
                accu[x] <= '0;
            end
        end else begin
            for (x = 0; x < 48; x = x + 1) begin
                accu[x] <= accu_next[x];
            end
        end
    end

    // Outputs: extract MSBs to match A_bits dynamic range
    genvar t;
    generate
        for (t = 0; t < 16; t = t + 1) begin : OUTS
            assign OC0[t] = accu[t][ACC_bits-1 -: A_bits];
            assign OC1[t] = accu[t+16][ACC_bits-1 -: A_bits];
            assign OC2[t] = accu[t+32][ACC_bits-1 -: A_bits];
        end
    endgenerate

endmodule
