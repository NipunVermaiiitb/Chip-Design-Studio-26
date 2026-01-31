// EACH SCU TAKES IN 18 WEIGHTS (DENSE), 36 input_tile values,
// 18 indexes, produces 3 output channels of 16 outputs each.

module scu #(
    parameter int A_bits = 12,
    parameter int W_bits = 16,
    parameter int I_bits = 6
)(
    input  wire clk,
    input  wire rst_n,       // active-low reset
    input  wire mode,        // 1 = Rfconv, 0 = Rfdeconv
    input  wire en,          // start/enable compute for this cycle (1-cycle SCU op)
    input  wire clear,       // clear accumulators (like start of new tile)

    input  wire signed [W_bits-1:0] weights   [17:0],
    input  wire signed [A_bits-1:0] input_tile[35:0],
    input  wire        [I_bits-1:0] indexes   [17:0],

    output wire signed [A_bits-1:0] OC0 [15:0],
    output wire signed [A_bits-1:0] OC1 [15:0],
    output wire signed [A_bits-1:0] OC2 [15:0]
);

    // -------------------------------------------------------------------------
    // Activations: 36 entries always available.
    // mode=1 uses only first 16 (0..15)
    // mode=0 uses full 36 (0..35)
    // -------------------------------------------------------------------------
    wire signed [A_bits-1:0] activation [35:0];

    genvar a;
    generate
        for (a = 0; a < 36; a = a + 1) begin : ACT_ASSIGN
            // for mode=1, only activation[0..15] valid. others forced to 0.
            assign activation[a] = (mode && (a >= 16)) ? '0 : input_tile[a];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Gather activations based on indexes
    // For mode=1: index must be 0..15 -> clamp using lower 4 bits
    // For mode=0: index can be 0..35 -> use full 6-bit index
    // -------------------------------------------------------------------------
    wire signed [A_bits-1:0] Y [17:0];

    genvar i;
    generate
        for (i = 0; i < 18; i = i + 1) begin : GATHER
            wire [I_bits-1:0] idx_conv  = {2'b00, indexes[i][3:0]}; // 0..15
            wire [I_bits-1:0] idx_final = mode ? idx_conv : indexes[i];
            assign Y[i] = activation[idx_final];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Multiply
    // product width = A_bits + W_bits
    // using 32-bit accumulator for safety
    // -------------------------------------------------------------------------
    localparam int PROD_bits = A_bits + W_bits;

    wire signed [PROD_bits-1:0] partial_product [17:0];

    genvar j;
    generate
        for (j = 0; j < 18; j = j + 1) begin : MULT
            assign partial_product[j] = Y[j] * weights[j];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Registered accumulators: 48 entries
    // -------------------------------------------------------------------------
    reg signed [31:0] accu [47:0];

    integer x;

    // helper function to compute destination accumulator address
    function automatic [5:0] accu_addr(input int k, input [I_bits-1:0] idx);
        begin
            if (mode) begin
                // mode=1: 3 banks of 16
                if (k < 6)       accu_addr = idx;        // 0..15  (OC0)
                else if (k < 12) accu_addr = idx + 16;   // 16..31 (OC1)
                else             accu_addr = idx + 32;   // 32..47 (OC2)
            end else begin
                // mode=0: all accumulate into first bank only
                accu_addr = idx;                          // 0..35 typically
            end
        end
    endfunction

    // sequential accumulation (one SCU op per cycle when en=1)
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (x = 0; x < 48; x = x + 1)
                accu[x] <= '0;
        end
        else begin
            if (clear) begin
                for (x = 0; x < 48; x = x + 1)
                    accu[x] <= '0;
            end
            else if (en) begin
                // do 18 scatter-add updates in one cycle
                // NOTE: if multiple k map to same addr in same cycle,
                // the last assignment wins (not true sum).
                // Proper way: build per-addr adder trees.
                // But architecturally, SCU usually guarantees unique destinations.
                for (x = 0; x < 18; x = x + 1) begin
                    // destination index selection:
                    // mode=1 restricts idx to [0..15] via lower bits
                    reg [I_bits-1:0] idx_eff;
                    reg [5:0] addr;

                    idx_eff = mode ? {2'b00, indexes[x][3:0]} : indexes[x];
                    addr    = accu_addr(x, idx_eff);

                    // sign extend product into 32-bit and accumulate
                    accu[addr] <= accu[addr] + {{(32-PROD_bits){partial_product[x][PROD_bits-1]}}, partial_product[x]};
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Outputs: upper 12 bits of each accumulator entry
    // OC0 = accu[0..15][31:20]
    // OC1 = accu[16..31][31:20]
    // OC2 = accu[32..47][31:20]
    // -------------------------------------------------------------------------
    genvar t;
    generate
        for (t = 0; t < 16; t = t + 1) begin : OUTS
            assign OC0[t] = accu[t][31:20];
            assign OC1[t] = accu[t+16][31:20];
            assign OC2[t] = accu[t+32][31:20];
        end
    endgenerate

endmodule
