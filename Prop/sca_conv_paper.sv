// sca_conv_paper.sv
// Generalized SCA core.
//
// - List-driven 4x4 conv mode: paper-style single SCU update producing 3 output channels.
// - Generic fallback mode: index-driven sparse scheduler producing a single N_ROWS x N_COLS tile.
//
// This lets SFTM use one module name for both conv (paper-faithful path) and deconv (6x6).

`timescale 1ns/1ps

module sca_conv_paper #(
    parameter int DATA_W = 16,
    parameter int ACC_W  = 32,
    parameter int N_ROWS = 4,
    parameter int N_COLS = 4,
    parameter int WEIGHT_ADDR_W = 12,
    parameter int INDEX_ADDR_W  = 10
)(
    input  wire clk,
    input  wire rst_n,

    input  wire valid_in,
    input  wire use_list_mode,
    input  wire signed [DATA_W-1:0] y_in [0:N_ROWS-1][0:N_COLS-1],

    // Dense matrices (used by fallback scheduler)
    input  wire signed [DATA_W-1:0] weight_data [0:N_ROWS-1][0:N_COLS-1],
    input  wire [INDEX_ADDR_W-1:0]  index_data  [0:N_ROWS-1][0:N_COLS-1],

    // 18 sparse weights + 18 indexes (used by paper list-driven conv mode)
    input  wire signed [DATA_W-1:0] weights18 [0:17],
    input  wire [5:0]               indexes18 [0:17],

    output reg  [WEIGHT_ADDR_W-1:0] weight_addr,
    output reg  [INDEX_ADDR_W-1:0]  index_addr,

    output reg  valid_out,
    // Fallback output (valid when !use_list_mode or when N_ROWS*N_COLS != 16)
    output reg  signed [ACC_W-1:0] u_out  [0:N_ROWS-1][0:N_COLS-1],
    // List-driven conv outputs (valid when use_list_mode && N_ROWS*N_COLS==16)
    output reg  signed [ACC_W-1:0] u0_out [0:3][0:3],
    output reg  signed [ACC_W-1:0] u1_out [0:3][0:3],
    output reg  signed [ACC_W-1:0] u2_out [0:3][0:3]
);

    localparam int IN_SIZE  = N_ROWS * N_COLS;
    localparam int IDX_BITS = (IN_SIZE <= 1) ? 1 : $clog2(IN_SIZE);
    wire list_mode_active = use_list_mode && (IN_SIZE == 16);

    // -------------------------------------------------------------------------
    // List-driven paper SCU conv path (only defined for 4x4)
    // -------------------------------------------------------------------------
    wire signed [DATA_W-1:0] input_tile36 [0:35];
    genvar fa;
    generate
        for (fa = 0; fa < 36; fa = fa + 1) begin : FLAT_ACT
            if (fa < 16) begin
                assign input_tile36[fa] = y_in[fa[3:2]][fa[1:0]];
            end else begin
                assign input_tile36[fa] = '0;
            end
        end
    endgenerate

    wire signed [DATA_W-1:0] OC0 [0:15];
    wire signed [DATA_W-1:0] OC1 [0:15];
    wire signed [DATA_W-1:0] OC2 [0:15];

    reg scu_clear, scu_en;

    scu_paper #(
        .A_bits(DATA_W),
        .W_bits(DATA_W),
        .I_bits(6),
        .ACC_bits(ACC_W)
    ) u_scu (
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

    typedef enum logic [1:0] {S_IDLE=2'd0, S_CLEAR=2'd1, S_EN=2'd2, S_OUT=2'd3} st_t;
    st_t st;

    // -------------------------------------------------------------------------
    // Generic fallback scheduler path (works for 4x4, 6x6, ...)
    // -------------------------------------------------------------------------
    reg signed [DATA_W-1:0] y_reg_flat [0:IN_SIZE-1];
    reg signed [DATA_W-1:0] h_reg_flat [0:IN_SIZE-1];
    reg [INDEX_ADDR_W-1:0]  s_reg_flat [0:IN_SIZE-1];
    reg signed [ACC_W-1:0] psum [0:IN_SIZE-1];

    reg fallback_busy;
    reg [$clog2(IN_SIZE+1)-1:0] k;

    wire entry_en;
    wire [IDX_BITS-1:0] entry_src;
    wire [IDX_BITS-1:0] entry_dst;
    assign entry_en  = s_reg_flat[k][INDEX_ADDR_W-1];
    assign entry_src = s_reg_flat[k][IDX_BITS-1:0];
    assign entry_dst = s_reg_flat[k][(2*IDX_BITS)-1:IDX_BITS];

    wire signed [DATA_W-1:0] h_cur = h_reg_flat[k];
    wire signed [DATA_W-1:0] y_cur = y_reg_flat[entry_src];
    wire do_mac = fallback_busy && entry_en && (h_cur != 0);
    wire signed [ACC_W-1:0] prod = $signed(y_cur) * $signed(h_cur);

    integer r, c;
    integer ai;

    // Address generation (simplified per-tile counter; kept for compatibility)
    reg [WEIGHT_ADDR_W-1:0] addr_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            valid_out <= 1'b0;
            scu_clear <= 1'b0;
            scu_en <= 1'b0;
            fallback_busy <= 1'b0;
            k <= '0;

            addr_cnt <= '0;
            weight_addr <= '0;
            index_addr <= '0;

            for (r = 0; r < N_ROWS; r = r + 1) begin
                for (c = 0; c < N_COLS; c = c + 1) begin
                    u_out[r][c] <= '0;
                end
            end
            for (r = 0; r < 4; r = r + 1) begin
                for (c = 0; c < 4; c = c + 1) begin
                    u0_out[r][c] <= '0;
                    u1_out[r][c] <= '0;
                    u2_out[r][c] <= '0;
                end
            end
            for (ai = 0; ai < IN_SIZE; ai = ai + 1) begin
                y_reg_flat[ai] <= '0;
                h_reg_flat[ai] <= '0;
                s_reg_flat[ai] <= '0;
                psum[ai] <= '0;
            end
        end else begin
            valid_out <= 1'b0;
            scu_clear <= 1'b0;
            scu_en <= 1'b0;

            // Basic address counter on tile accept
            if (valid_in) begin
                weight_addr <= addr_cnt;
                index_addr <= addr_cnt[INDEX_ADDR_W-1:0];
                addr_cnt <= addr_cnt + 1'b1;
            end

            // ------------------------------
            // Paper list-driven 4x4 path
            // ------------------------------
            if (list_mode_active) begin
                case (st)
                    S_IDLE: begin
                        if (valid_in) st <= S_CLEAR;
                    end

                    S_CLEAR: begin
                        scu_clear <= 1'b1;
                        st <= S_EN;
                    end

                    S_EN: begin
                        scu_en <= 1'b1;
                        st <= S_OUT;
                    end

                    S_OUT: begin
                        for (r = 0; r < 4; r = r + 1) begin
                            for (c = 0; c < 4; c = c + 1) begin
                                u0_out[r][c] <= OC0[{r[1:0], c[1:0]}];
                                u1_out[r][c] <= OC1[{r[1:0], c[1:0]}];
                                u2_out[r][c] <= OC2[{r[1:0], c[1:0]}];
                            end
                        end
                        valid_out <= 1'b1;
                        st <= S_IDLE;
                    end

                    default: st <= S_IDLE;
                endcase
            end else begin
                st <= S_IDLE;
            end

            // ------------------------------
            // Fallback scheduler path
            // ------------------------------
            if (!list_mode_active) begin
                // Latch a new tile and initialize accumulators
                if (valid_in && !fallback_busy) begin
                    for (r = 0; r < N_ROWS; r = r + 1) begin
                        for (c = 0; c < N_COLS; c = c + 1) begin
                            y_reg_flat[r*N_COLS + c] <= y_in[r][c];
                            h_reg_flat[r*N_COLS + c] <= weight_data[r][c];
                            s_reg_flat[r*N_COLS + c] <= index_data[r][c];
                        end
                    end
                    for (ai = 0; ai < IN_SIZE; ai = ai + 1) begin
                        psum[ai] <= '0;
                    end
                    k <= '0;
                    fallback_busy <= 1'b1;
                end

                if (fallback_busy) begin
                    if (do_mac) begin
                        psum[entry_dst] <= psum[entry_dst] + prod;
                    end

                    if (k == IN_SIZE-1) begin
                        for (r = 0; r < N_ROWS; r = r + 1) begin
                            for (c = 0; c < N_COLS; c = c + 1) begin
                                u_out[r][c] <= psum[r*N_COLS + c];
                            end
                        end
                        valid_out <= 1'b1;
                        fallback_busy <= 1'b0;
                    end else begin
                        k <= k + 1'b1;
                    end
                end
            end
        end
    end

endmodule
