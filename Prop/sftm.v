// sftm.v
// Top-level SFTM: Full pipeline PreTA -> SCA -> PosTA -> QMU
// Produces group_data per GROUP_ROWS rows and asserts group_done.
// Supports both convolution (4x4->2x2) and deconvolution (4x4->4x4) modes

`timescale 1ns/1ps
module sftm #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4,
    parameter WEIGHT_ADDR_W = 12,
    parameter INDEX_ADDR_W = 10
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    
    // Input data stream (feature patches)
    input wire [DATA_W-1:0] input_data,
    input wire input_valid,
    
    // Operation mode
    input wire conv_mode,       // 1=conv, 0=deconv
    input wire [1:0] quality_mode,
    
    // Weight memory interface
    output wire [WEIGHT_ADDR_W-1:0] weight_addr,
    input wire signed [DATA_W-1:0] weight_data [0:3][0:3],
    
    // Outputs
    output reg group_valid,
    output reg group_done,
    output reg [DATA_W-1:0] group_data,
    output reg group_data_valid,
    input wire bypass_mode
);

// ====== Input Buffer: Collect 4x4 patches ======
reg signed [DATA_W-1:0] input_buffer [0:3][0:3];
reg [4:0] buf_cnt;
reg buf_ready;

integer bi, bj;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        buf_cnt <= 0;
        buf_ready <= 0;
        for (bi = 0; bi < 4; bi = bi + 1)
            for (bj = 0; bj < 4; bj = bj + 1)
                input_buffer[bi][bj] <= 0;
    end else if (input_valid && start) begin
        // Fill buffer row-major
        input_buffer[buf_cnt[4:2]][buf_cnt[1:0]] <= input_data;
        buf_cnt <= buf_cnt + 1;
        if (buf_cnt == 15) begin
            buf_ready <= 1'b1;
            buf_cnt <= 0;
        end else begin
            buf_ready <= 1'b0;
        end
    end else begin
        buf_ready <= 1'b0;
    end
end

// ====== PreTA Stage ======
wire preta_valid_conv, preta_valid_deconv;
wire signed [ACC_W-1:0] preta_out_conv [0:3][0:3];
wire signed [ACC_W-1:0] preta_out_deconv [0:5][0:5];

// PreTA for convolution (4x4 -> 4x4)
preta_conv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_preta_conv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(buf_ready && conv_mode),
    .patch_in(input_buffer),
    .valid_out(preta_valid_conv),
    .patch_out(preta_out_conv)
);

// PreTA for deconvolution (4x4 -> 6x6)
preta_deconv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_preta_deconv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(buf_ready && !conv_mode),
    .patch_in(input_buffer),
    .valid_out(preta_valid_deconv),
    .patch_out(preta_out_deconv)
);

// ====== SCA Stage ======
// For simplicity, using 4x4 SCA (can be extended for 6x6 deconv)
wire sca_valid;
wire signed [ACC_W-1:0] sca_out [0:3][0:3];
wire [WEIGHT_ADDR_W-1:0] sca_weight_addr;

// Convert PreTA output to DATA_W for SCA input (with saturation)
reg signed [DATA_W-1:0] sca_in [0:3][0:3];
integer si, sj;
always @(*) begin
    for (si = 0; si < 4; si = si + 1) begin
        for (sj = 0; sj < 4; sj = sj + 1) begin
            // Saturation logic
            if (preta_out_conv[si][sj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                sca_in[si][sj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (preta_out_conv[si][sj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                sca_in[si][sj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                sca_in[si][sj] = preta_out_conv[si][sj][DATA_W-1:0];
        end
    end
end

sca #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .N_ROWS(4),
    .N_COLS(4),
    .WEIGHT_ADDR_W(WEIGHT_ADDR_W)
) u_sca (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(preta_valid_conv),
    .y_in(sca_in),
    .weight_data(weight_data),
    .weight_addr(sca_weight_addr),
    .valid_out(sca_valid),
    .u_out(sca_out)
);

assign weight_addr = sca_weight_addr;

// ====== PosTA Stage ======
wire posta_valid;
wire signed [ACC_W-1:0] posta_out [0:1][0:1];

// Convert SCA output to DATA_W for PosTA
reg signed [DATA_W-1:0] posta_in [0:3][0:3];
integer pi, pj;
always @(*) begin
    for (pi = 0; pi < 4; pi = pi + 1) begin
        for (pj = 0; pj < 4; pj = pj + 1) begin
            // Saturation
            if (sca_out[pi][pj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                posta_in[pi][pj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (sca_out[pi][pj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                posta_in[pi][pj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                posta_in[pi][pj] = sca_out[pi][pj][DATA_W-1:0];
        end
    end
end

posta_conv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_posta_conv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sca_valid),
    .patch_in(posta_in),
    .valid_out(posta_valid),
    .patch_out(posta_out)
);

// ====== QMU Stage (Quality Modulation) ======
wire qmu_valid;
wire [DATA_W-1:0] qmu_out;
reg [DATA_W-1:0] qmu_in;
reg qmu_in_valid;
reg [1:0] out_cnt;

// Serialize 2x2 output for QMU processing
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        qmu_in <= 0;
        qmu_in_valid <= 0;
        out_cnt <= 0;
    end else if (posta_valid) begin
        case (out_cnt)
            2'd0: qmu_in <= posta_out[0][0][DATA_W-1:0];
            2'd1: qmu_in <= posta_out[0][1][DATA_W-1:0];
            2'd2: qmu_in <= posta_out[1][0][DATA_W-1:0];
            2'd3: qmu_in <= posta_out[1][1][DATA_W-1:0];
        endcase
        qmu_in_valid <= 1'b1;
        out_cnt <= out_cnt + 1;
    end else begin
        qmu_in_valid <= 1'b0;
    end
end

qmu #(
    .DATA_W(DATA_W)
) u_qmu (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(qmu_in_valid),
    .data_in(qmu_in),
    .quality_mode(quality_mode),
    .valid_out(qmu_valid),
    .data_out(qmu_out)
);

// ====== Output Management ======
reg [3:0] row_cnt;
reg processing;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        group_valid <= 0;
        group_done <= 0;
        group_data <= 0;
        group_data_valid <= 0;
        row_cnt <= 0;
        processing <= 0;
    end else begin
        group_done <= 1'b0;
        
        if (start && !processing) begin
            processing <= 1'b1;
            group_valid <= 1'b1;
            row_cnt <= 0;
        end
        
        if (bypass_mode && input_valid) begin
            // Bypass: pass through directly
            group_data <= input_data;
            group_data_valid <= 1'b1;
            row_cnt <= row_cnt + 1;
            if (row_cnt == (GROUP_ROWS-1)) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                row_cnt <= 0;
            end
        end else if (qmu_valid) begin
            // Normal mode: output from QMU
            group_data <= qmu_out;
            group_data_valid <= 1'b1;
            row_cnt <= row_cnt + 1;
            if (row_cnt == (GROUP_ROWS-1)) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                row_cnt <= 0;
            end
        end else begin
            group_data_valid <= 1'b0;
        end
    end
end

endmodule
