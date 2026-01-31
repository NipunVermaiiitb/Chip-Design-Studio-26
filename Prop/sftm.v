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
    input wire conv_mode,       // 1=conv, 0=deconv
    input wire [1:0] quality_mode,
    
    // Weight memory interface
    output wire [WEIGHT_ADDR_W-1:0] weight_addr,
    input wire signed [DATA_W-1:0] weight_data [0:3][0:3],
    
    // Index memory interface (for sparse computing)
    output wire [INDEX_ADDR_W-1:0] index_addr,
    input wire [INDEX_ADDR_W-1:0] index_data [0:3][0:3],
    
    // Outputs
    output reg group_valid,
    output reg group_done,
    output reg [DATA_W-1:0] group_data,
    output reg group_data_valid,
    input wire bypass_mode
);

// ====== IQMU Stage (Inverse Quality Modulation for Synthesis/Decoding) ======
// Applied BEFORE transformation to dequantize compressed features
wire iqmu_valid;
wire [DATA_W-1:0] iqmu_out;
reg iqmu_enable;

// Determine if we're in synthesis (decoding) mode
// In synthesis mode, apply IQMU first; in analysis mode, apply QMU last
always @(*) begin
    // Simple heuristic: if we're doing deconv, assume synthesis mode
    iqmu_enable = !conv_mode;  // Deconv typically used in synthesis
end

iqmu #(
    .DATA_W(DATA_W)
) u_iqmu (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(input_valid && iqmu_enable),
    .data_in(input_data),
    .quality_mode(quality_mode),
    .valid_out(iqmu_valid),
    .data_out(iqmu_out)
);

// Select between IQMU output (synthesis) or direct input (analysis)
wire [DATA_W-1:0] buf_input_data;
wire buf_input_valid;
assign buf_input_data = iqmu_enable ? iqmu_out : input_data;
assign buf_input_valid = iqmu_enable ? iqmu_valid : input_valid;

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
    end else if (buf_input_valid && start) begin
        // Fill buffer row-major (using IQMU output if in synthesis mode)
        input_buffer[buf_cnt[4:2]][buf_cnt[1:0]] <= buf_input_data;
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
// Separate paths for convolution (4x4) and deconvolution (6x6)

// Convolution path: 4x4 SCA
wire sca_valid_conv;
wire signed [ACC_W-1:0] sca_out_conv [0:3][0:3];
wire [WEIGHT_ADDR_W-1:0] sca_weight_addr_conv;
wire [INDEX_ADDR_W-1:0] sca_index_addr_conv;

// Extend 4x4 index_data input for SCA (direct mapping)
reg [INDEX_ADDR_W-1:0] index_data_4x4 [0:3][0:3];
integer ii, ij;
always @(*) begin
    for (ii = 0; ii < 4; ii = ii + 1) begin
        for (ij = 0; ij < 4; ij = ij + 1) begin
            index_data_4x4[ii][ij] = index_data[ii][ij];
        end
    end
end

reg signed [DATA_W-1:0] sca_in_conv [0:3][0:3];
integer si, sj;
always @(*) begin
    for (si = 0; si < 4; si = si + 1) begin
        for (sj = 0; sj < 4; sj = sj + 1) begin
            // Saturation logic
            if (preta_out_conv[si][sj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                sca_in_conv[si][sj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (preta_out_conv[si][sj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                sca_in_conv[si][sj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                sca_in_conv[si][sj] = preta_out_conv[si][sj][DATA_W-1:0];
        end
    end
end

sca #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .N_ROWS(4),
    .N_COLS(4),
    .WEIGHT_ADDR_W(WEIGHT_ADDR_W),
    .INDEX_ADDR_W(INDEX_ADDR_W)
) u_sca_conv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(preta_valid_conv),
    .y_in(sca_in_conv),
    .weight_data(weight_data),
    .index_data(index_data_4x4),
    .weight_addr(sca_weight_addr_conv),
    .index_addr(sca_index_addr_conv),
    .valid_out(sca_valid_conv),
    .u_out(sca_out_conv)
);

// Deconvolution path: 6x6 SCA
wire sca_valid_deconv;
wire signed [ACC_W-1:0] sca_out_deconv [0:5][0:5];
wire [WEIGHT_ADDR_W-1:0] sca_weight_addr_deconv;
wire [INDEX_ADDR_W-1:0] sca_index_addr_deconv;

// Need 6x6 weight data for deconv - extend from 4x4 (pad with zeros)
reg [INDEX_ADDR_W-1:0] index_data_6x6 [0:5][0:5];
integer idi, idj;
always @(*) begin
    for (idi = 0; idi < 6; idi = idi + 1) begin
        for (idj = 0; idj < 6; idj = idj + 1) begin
            if (idi < 4 && idj < 4)
                index_data_6x6[idi][idj] = index_data[idi][idj];
            else
                index_data_6x6[idi][idj] = 0;
        end
    end
end

// Need 6x6 weight data for deconv - extend from 4x4 (pad with zeros)
reg signed [DATA_W-1:0] weight_data_6x6 [0:5][0:5];
integer wi, wj;
always @(*) begin
    for (wi = 0; wi < 6; wi = wi + 1) begin
        for (wj = 0; wj < 6; wj = wj + 1) begin
            if (wi < 4 && wj < 4)
                weight_data_6x6[wi][wj] = weight_data[wi][wj];
            else
                weight_data_6x6[wi][wj] = 0;
        end
    end
end

reg signed [DATA_W-1:0] sca_in_deconv [0:5][0:5];
integer di, dj;
always @(*) begin
    for (di = 0; di < 6; di = di + 1) begin
        for (dj = 0; dj < 6; dj = dj + 1) begin
            // Saturation logic
            if (preta_out_deconv[di][dj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                sca_in_deconv[di][dj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (preta_out_deconv[di][dj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                sca_in_deconv[di][dj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                sca_in_deconv[di][dj] = preta_out_deconv[di][dj][DATA_W-1:0];
        end
    end
end

sca #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .N_ROWS(6),
    .N_COLS(6),
    .WEIGHT_ADDR_W(WEIGHT_ADDR_W),
    .INDEX_ADDR_W(INDEX_ADDR_W)
) u_sca_deconv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(preta_valid_deconv),
    .y_in(sca_in_deconv),
    .weight_data(weight_data_6x6),
    .index_data(index_data_6x6),
    .weight_addr(sca_weight_addr_deconv),
    .index_addr(sca_index_addr_deconv),
    .valid_out(sca_valid_deconv),
    .u_out(sca_out_deconv)
);

// Mux weight and index addresses based on mode
assign weight_addr = conv_mode ? sca_weight_addr_conv : sca_weight_addr_deconv;
assign index_addr = conv_mode ? sca_index_addr_conv : sca_index_addr_deconv;

// ====== PosTA Stage ======
// Convolution path: 4x4 -> 2x2
wire posta_valid_conv;
wire signed [ACC_W-1:0] posta_out_conv [0:1][0:1];

reg signed [DATA_W-1:0] posta_in_conv [0:3][0:3];
integer pi, pj;
always @(*) begin
    for (pi = 0; pi < 4; pi = pi + 1) begin
        for (pj = 0; pj < 4; pj = pj + 1) begin
            // Saturation
            if (sca_out_conv[pi][pj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                posta_in_conv[pi][pj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (sca_out_conv[pi][pj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                posta_in_conv[pi][pj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                posta_in_conv[pi][pj] = sca_out_conv[pi][pj][DATA_W-1:0];
        end
    end
end

posta_conv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_posta_conv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sca_valid_conv),
    .patch_in(posta_in_conv),
    .valid_out(posta_valid_conv),
    .patch_out(posta_out_conv)
);

// Deconvolution path: 6x6 -> 4x4
wire posta_valid_deconv;
wire signed [ACC_W-1:0] posta_out_deconv [0:3][0:3];

reg signed [DATA_W-1:0] posta_in_deconv [0:5][0:5];
integer pdi, pdj;
always @(*) begin
    for (pdi = 0; pdi < 6; pdi = pdi + 1) begin
        for (pdj = 0; pdj < 6; pdj = pdj + 1) begin
            // Saturation
            if (sca_out_deconv[pdi][pdj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                posta_in_deconv[pdi][pdj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (sca_out_deconv[pdi][pdj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                posta_in_deconv[pdi][pdj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                posta_in_deconv[pdi][pdj] = sca_out_deconv[pdi][pdj][DATA_W-1:0];
        end
    end
end

posta_deconv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_posta_deconv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sca_valid_deconv),
    .patch_in(posta_in_deconv),
    .valid_out(posta_valid_deconv),
    .patch_out(posta_out_deconv)
);

// Mux PosTA outputs based on mode
wire posta_valid;
assign posta_valid = conv_mode ? posta_valid_conv : posta_valid_deconv;

// ====== Reshuffle Network (between PosTA and output buffer/QMU feed) ======
// Paper Fig. 3(b) places a reshuffle network after PosT to deal with overlapped tiles.
// In this streaming SFTM, we model it as a deterministic row-rotation per tile.
reg [1:0] reshuffle_step;
wire signed [ACC_W-1:0] posta_deconv_reshuffled [0:3][0:3];

reshuffle_network #(
    .N(4),
    .WIDTH(ACC_W)
) u_reshuffle (
    .step(reshuffle_step),
    .in_patch(posta_out_deconv),
    .out_patch(posta_deconv_reshuffled)
);

// ====== QMU Stage (Quality Modulation) ======
wire qmu_valid;
wire [DATA_W-1:0] qmu_out;
reg [DATA_W-1:0] qmu_in;
reg qmu_in_valid;
reg [1:0] out_cnt;

// Serialize output for QMU processing
// Conv mode: serialize 2x2 (4 samples) from posta_out_conv
// Deconv mode: serialize 4x4 (16 samples) from reshuffled posta_out_deconv
reg [4:0] serialize_cnt;
reg [4:0] serialize_max;
reg serializing;

reg signed [ACC_W-1:0] post2_reg [0:1][0:1];
reg signed [ACC_W-1:0] post4_reg [0:3][0:3];
integer sri, srj;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        qmu_in <= 0;
        qmu_in_valid <= 0;
        serialize_cnt <= 0;
        serialize_max <= 0;
        serializing <= 0;
        reshuffle_step <= 0;
        for (sri = 0; sri < 2; sri = sri + 1)
            for (srj = 0; srj < 2; srj = srj + 1)
                post2_reg[sri][srj] <= 0;
        for (sri = 0; sri < 4; sri = sri + 1)
            for (srj = 0; srj < 4; srj = srj + 1)
                post4_reg[sri][srj] <= 0;
    end else begin
        qmu_in_valid <= 1'b0;

        // Capture a completed PosTA tile into local regs (acts like an output buffer)
        if (posta_valid && !serializing) begin
            if (conv_mode) begin
                for (sri = 0; sri < 2; sri = sri + 1)
                    for (srj = 0; srj < 2; srj = srj + 1)
                        post2_reg[sri][srj] <= posta_out_conv[sri][srj];
            end else begin
                for (sri = 0; sri < 4; sri = sri + 1)
                    for (srj = 0; srj < 4; srj = srj + 1)
                        post4_reg[sri][srj] <= posta_deconv_reshuffled[sri][srj];
                reshuffle_step <= reshuffle_step + 1'b1; // advance per accepted tile
            end

            serializing <= 1'b1;
            serialize_cnt <= 0;
            serialize_max <= conv_mode ? 5'd3 : 5'd15;
        end

        // Stream the captured tile into QMU
        if (serializing) begin
            qmu_in_valid <= 1'b1;
            if (conv_mode) begin
                // 2x2: cnt[1]=row, cnt[0]=col (0..3)
                qmu_in <= post2_reg[serialize_cnt[1]][serialize_cnt[0]][DATA_W-1:0];
            end else begin
                // 4x4: row-major (0..15)
                qmu_in <= post4_reg[serialize_cnt[4:2]][serialize_cnt[1:0]][DATA_W-1:0];
            end

            if (serialize_cnt == serialize_max) begin
                serializing <= 1'b0;
            end else begin
                serialize_cnt <= serialize_cnt + 1'b1;
            end
        end
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
reg [4:0] output_cnt;
reg [4:0] output_max;
reg processing;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        group_valid <= 0;
        group_done <= 0;
        group_data <= 0;
        group_data_valid <= 0;
        output_cnt <= 0;
        output_max <= 0;
        processing <= 0;
    end else begin
        group_done <= 1'b0;
        
        if (start && !processing) begin
            processing <= 1'b1;
            group_valid <= 1'b1;
            output_cnt <= 0;
            // Conv outputs 4 pixels (2x2), Deconv outputs 16 pixels (4x4)
            output_max <= conv_mode ? 5'd3 : 5'd15;
        end
        
        if (bypass_mode && input_valid) begin
            // Bypass: pass through directly
            group_data <= input_data;
            group_data_valid <= 1'b1;
            output_cnt <= output_cnt + 1;
            if (output_cnt == output_max) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                output_cnt <= 0;
            end
        end else if (qmu_valid) begin
            // Normal mode: output from QMU
            group_data <= qmu_out;
            group_data_valid <= 1'b1;
            output_cnt <= output_cnt + 1;
            if (output_cnt == output_max) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                output_cnt <= 0;
            end
        end else begin
            group_data_valid <= 1'b0;
        end
    end
end

endmodule