// sca_conv_paper.sv
// Paper-style SCA conv core using one SCU that computes 3 output channels in parallel.
//
// Interface is intentionally narrow (single 4x4 input tile) and emits 3 transform-domain
// output tiles (one per filter) so SFTM can run PosTA per channel.

`timescale 1ns/1ps

module sca_conv_paper #(
    parameter int DATA_W = 16,
    parameter int ACC_W  = 32
)(
    input  wire clk,
    input  wire rst_n,

    input  wire valid_in,
    input  wire signed [DATA_W-1:0] y_in [0:3][0:3],

    // 18 sparse weights + 18 indexes (6 per output channel)
    input  wire signed [DATA_W-1:0] weights18 [0:17],
    input  wire [5:0]               indexes18 [0:17],

    output reg  valid_out,
    output reg  signed [ACC_W-1:0] u0_out [0:3][0:3],
    output reg  signed [ACC_W-1:0] u1_out [0:3][0:3],
    output reg  signed [ACC_W-1:0] u2_out [0:3][0:3]
);

    // Flatten activations to 36 entries as the SCU expects; only 0..15 are used.
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

    typedef enum reg [1:0] {S_IDLE=2'd0, S_CLEAR=2'd1, S_EN=2'd2, S_OUT=2'd3} st_t;
    st_t st;

    integer r, c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            valid_out <= 1'b0;
            scu_clear <= 1'b0;
            scu_en <= 1'b0;
            for (r=0;r<4;r=r+1) begin
                for (c=0;c<4;c=c+1) begin
                    u0_out[r][c] <= '0;
                    u1_out[r][c] <= '0;
                    u2_out[r][c] <= '0;
                end
            end
        end else begin
            valid_out <= 1'b0;
            scu_clear <= 1'b0;
            scu_en <= 1'b0;

            case (st)
                S_IDLE: begin
                    if (valid_in) st <= S_CLEAR;
                end

                S_CLEAR: begin
                    // clear accumulators
                    scu_clear <= 1'b1;
                    st <= S_EN;
                end

                S_EN: begin
                    // apply one SCU update cycle
                    scu_en <= 1'b1;
                    st <= S_OUT;
                end

                S_OUT: begin
                    // capture results (accu regs updated after S_EN)
                    for (r=0;r<4;r=r+1) begin
                        for (c=0;c<4;c=c+1) begin
                            u0_out[r][c] <= OC0[{r[1:0],c[1:0]}];
                            u1_out[r][c] <= OC1[{r[1:0],c[1:0]}];
                            u2_out[r][c] <= OC2[{r[1:0],c[1:0]}];
                        end
                    end
                    valid_out <= 1'b1;
                    st <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
