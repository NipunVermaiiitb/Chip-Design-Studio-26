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

    // Deconv motion-vector second channel weights (dy)
    input wire signed [DATA_W-1:0] weight_data_dy [0:3][0:3],

	 // Paper-SCU sparse lists for RFConv (3 filters × ~6 nonzeros each)
	 input wire signed [DATA_W-1:0] scu_weights [0:17],
	 input wire [5:0]               scu_indexes [0:17],

	 // Index memory interface (legacy/fallback sparse computing)
	 output wire [INDEX_ADDR_W-1:0] index_addr,
	 input wire [INDEX_ADDR_W-1:0] index_data [0:3][0:3],
	    input wire [INDEX_ADDR_W-1:0] index_data_dy [0:3][0:3],

	 // Hybrid Layer Fusion control
	 input wire layer_seq_mode,
	 input wire [WEIGHT_ADDR_W-1:0] seq_wbase0,
	 input wire [WEIGHT_ADDR_W-1:0] seq_wbase1,
	 input wire [WEIGHT_ADDR_W-1:0] seq_wbase2,
    
    // Outputs
    output reg group_valid,
    output reg group_done,
    output reg [DATA_W-1:0] group_data,
    output reg group_data_valid,
    input wire bypass_mode
);

//==============================================================================
// Hybrid Layer Fusion Sequencer (minimal)
// RFConv0 -> RFConv1 -> RFDeConv chaining when layer_seq_mode=1.
// External group_done/group_data_valid only assert on final (deconv) stage.
//==============================================================================

localparam [1:0] SEQ_STAGE_CONV0  = 2'd0;
localparam [1:0] SEQ_STAGE_CONV1  = 2'd1;
localparam [1:0] SEQ_STAGE_DECONV = 2'd2;

// Paper-faithful intermediate tensor depth for RepVCN fusion
localparam integer FUSED_CH = 32;
localparam integer SCU_OUT_PAR = 3;
localparam integer CHANNEL_LOOP_COUNT = (FUSED_CH + SCU_OUT_PAR - 1) / SCU_OUT_PAR; // ceil(32/3)=11
localparam integer WEIGHTS_PER_PASS = 18; // 18 sparse weights/indexes per SCU invocation

reg seq_active;
reg [1:0] seq_stage;
reg seq_load_internal;
reg seq_finish_pulse;
reg seq_enter_conv1;
reg seq_enter_deconv;

// Intermediate banks: planar (channel-major), each channel stores the 36-entry SCU tile.
// Entries 0..15 carry the 4x4 transform coefficients; 16..35 are zero (padding).
reg signed [DATA_W-1:0] bank_in_tile36 [0:FUSED_CH-1][0:35];
reg signed [DATA_W-1:0] bank0_tile36 [0:FUSED_CH-1][0:35];
reg signed [DATA_W-1:0] bank1_tile36 [0:FUSED_CH-1][0:35];

// RFConv0 input loader (builds planar BankIn from the external stream via PreTA)
reg [4:0] rf0_load_ch;
reg rf0_inputs_ready;

// RFConv0 (standard conv): outer loop over output batches (ob0_idx), inner loop over input channels (ic0_idx)
reg [3:0] ob0_idx;
reg [4:0] ic0_idx;
reg conv0_done_pulse;

// RFConv1 (standard conv): outer loop over output-channel batches (ob_idx), inner loop over input channels (ic_idx)
reg [3:0] ob_idx;
reg [4:0] ic_idx;
reg conv1_done_pulse;

wire conv_stage_done_pulse;
assign conv_stage_done_pulse = conv0_done_pulse | conv1_done_pulse;

wire seq_is_final = (seq_stage == SEQ_STAGE_DECONV);
wire emit_external = (!layer_seq_mode) || (seq_active && seq_is_final);

wire op_conv_mode = layer_seq_mode ? (seq_active ? (seq_stage != SEQ_STAGE_DECONV) : conv_mode) : conv_mode;
wire [WEIGHT_ADDR_W-1:0] stage_wbase = (seq_stage == SEQ_STAGE_CONV0) ? seq_wbase0 :
									  (seq_stage == SEQ_STAGE_CONV1) ? seq_wbase1 :
																	   seq_wbase2;

wire in_seq_conv_stage = layer_seq_mode && seq_active && (seq_stage != SEQ_STAGE_DECONV);

// Weight-address mapping:
// - RFConv0: stage_wbase + ((ob0_idx*FUSED_CH) + ic0_idx)*18 (one 18-entry list per (input channel, output-batch))
// - RFConv1: stage_wbase + ((ob_idx*FUSED_CH) + ic_idx)*18 (one 18-entry list per (input channel, output-batch))
// - RFDeConv: stage_wbase
wire [WEIGHT_ADDR_W-1:0] rfconv1_pair_offset = ((ob_idx * FUSED_CH) + ic_idx) * WEIGHTS_PER_PASS;
wire [WEIGHT_ADDR_W-1:0] rfconv0_pair_offset = ((ob0_idx * FUSED_CH) + ic0_idx) * WEIGHTS_PER_PASS;
wire [WEIGHT_ADDR_W-1:0] seq_weight_base = (seq_stage == SEQ_STAGE_DECONV) ? stage_wbase :
                                  (seq_stage == SEQ_STAGE_CONV1)  ? (stage_wbase + rfconv1_pair_offset) :
													  (stage_wbase + rfconv0_pair_offset);

function automatic signed [DATA_W-1:0] sat_acc_to_data(input signed [ACC_W-1:0] v);
	begin
		 if (v > $signed({1'b0, {(DATA_W-1){1'b1}}}))
			 sat_acc_to_data = {1'b0, {(DATA_W-1){1'b1}}};
		 else if (v < $signed({1'b1, {(DATA_W-1){1'b0}}}))
			 sat_acc_to_data = {1'b1, {(DATA_W-1){1'b0}}};
		 else
			 sat_acc_to_data = v[DATA_W-1:0];
	end
endfunction

integer li;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rf0_load_ch <= 0;
		rf0_inputs_ready <= 1'b0;
		for (li = 0; li < FUSED_CH; li = li + 1) begin
			integer lj;
			for (lj = 0; lj < 36; lj = lj + 1) begin
				bank_in_tile36[li][lj] <= '0;
			end
		end
	end else begin
		// Default: keep until next fusion start
		if (!layer_seq_mode || !seq_active || (seq_stage != SEQ_STAGE_CONV0)) begin
			rf0_load_ch <= 0;
			rf0_inputs_ready <= 1'b0;
		end else begin
			// Capture each channel's PreTA output into BankIn
			if (preta_valid_conv && !rf0_inputs_ready) begin
				integer rr, cc;
				for (rr = 0; rr < 4; rr = rr + 1) begin
					for (cc = 0; cc < 4; cc = cc + 1) begin
						bank_in_tile36[rf0_load_ch][{rr[1:0], cc[1:0]}] <= sat_acc_to_data(preta_out_conv[rr][cc]);
					end
				end
				for (li = 16; li < 36; li = li + 1) begin
					bank_in_tile36[rf0_load_ch][li] <= '0;
				end

				if (rf0_load_ch == (FUSED_CH-1)) begin
					rf0_inputs_ready <= 1'b1;
				end else begin
					rf0_load_ch <= rf0_load_ch + 1'b1;
				end
			end
		end
	end
end

// ====== IQMU Stage (Inverse Quality Modulation for Synthesis/Decoding) ======
// Applied BEFORE transformation to dequantize compressed features
wire iqmu_valid;
wire [DATA_W-1:0] iqmu_out;
reg iqmu_enable;

// Determine if we're in synthesis (decoding) mode
// In synthesis mode, apply IQMU first; in analysis mode, apply QMU last
always @(*) begin
    // Simple heuristic: if we're doing deconv, assume synthesis mode
	 iqmu_enable = !op_conv_mode; 	// Deconv typically used in synthesis
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
reg buf_ready_force;

wire buf_ready_effective = buf_ready | buf_ready_force;
wire use_internal_source = layer_seq_mode && seq_active && (seq_stage == SEQ_STAGE_DECONV);

integer bi, bj;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        buf_cnt <= 0;
        buf_ready <= 0;
		 buf_ready_force <= 0;
        for (bi = 0; bi < 4; bi = bi + 1)
            for (bj = 0; bj < 4; bj = bj + 1)
                input_buffer[bi][bj] <= 0;
    end else begin
		 buf_ready_force <= 1'b0;

		 if (use_internal_source && seq_load_internal) begin
			 // Fill the 4x4 patch from the intermediate bank (channel 0) for RFDeConv input.
			 for (bi = 0; bi < 4; bi = bi + 1)
				 for (bj = 0; bj < 4; bj = bj + 1)
					 input_buffer[bi][bj] <= bank1_tile36[0][{bi[1:0], bj[1:0]}];

			 buf_cnt <= 0;
			 buf_ready <= 1'b0;
			 buf_ready_force <= 1'b1;
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
    .valid_in(buf_ready_effective && op_conv_mode),
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
    .valid_in(buf_ready_effective && !op_conv_mode),
    .patch_in(input_buffer),
    .valid_out(preta_valid_deconv),
    .patch_out(preta_out_deconv)
);

// ====== SCA Stage ======
// Separate paths for convolution (4x4) and deconvolution (6x6)

// Convolution path: 4x4 SCA
wire sca_valid_conv;
wire signed [ACC_W-1:0] sca_out_conv0 [0:3][0:3];
wire signed [ACC_W-1:0] sca_out_conv1 [0:3][0:3];
wire signed [ACC_W-1:0] sca_out_conv2 [0:3][0:3];
reg  [WEIGHT_ADDR_W-1:0] sca_weight_addr_conv;
reg  [INDEX_ADDR_W-1:0]  sca_index_addr_conv;

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
reg signed [DATA_W-1:0] sca_y_in_conv [0:3][0:3];
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

// Fusion-mode input selection for RFConv1: read from intermediate bank (channel 0 for now)
integer ci, cj;
always @(*) begin
	 for (ci = 0; ci < 4; ci = ci + 1) begin
		 for (cj = 0; cj < 4; cj = cj + 1) begin
			 if (layer_seq_mode && seq_active && (seq_stage == SEQ_STAGE_CONV1))
				 sca_y_in_conv[ci][cj] = bank0_tile36[0][{ci[1:0], cj[1:0]}];
			 else
				 sca_y_in_conv[ci][cj] = sca_in_conv[ci][cj];
		 end
	 end
end

wire sca_valid_in_conv;
assign sca_valid_in_conv = (!layer_seq_mode) ? preta_valid_conv : 1'b0;

sca_conv_paper #(
	 .DATA_W(DATA_W),
	 .ACC_W(ACC_W),
	 .N_ROWS(4),
	 .N_COLS(4),
	 .WEIGHT_ADDR_W(WEIGHT_ADDR_W),
	 .INDEX_ADDR_W(INDEX_ADDR_W)
) u_sca_conv (
	 .clk(clk),
	 .rst_n(rst_n),
	 .valid_in(sca_valid_in_conv),
	 .use_list_mode(1'b1),
	 .y_in(sca_y_in_conv),
	 .weight_data(weight_data),
	 .index_data(index_data_4x4),
	 .weights18(scu_weights),
	 .indexes18(scu_indexes),
	 .weight_addr(),
	 .index_addr(),
	 .valid_out(sca_valid_conv),
	 .u_out(),
	 .u0_out(sca_out_conv0),
	 .u1_out(sca_out_conv1),
	 .u2_out(sca_out_conv2)
);

//==============================================================================
// RFConv1 (RepVCN) standard convolution engine
// - Planar packing: BankA provides 36 activation entries for one input channel.
// - Output-stationary: for each output-batch (k,k+1,k+2), accumulate over ic=0..31.
// - Write-back: store the 3 resulting 4x4 tiles (coeffs 0..15) into BankB.
//==============================================================================

wire rf1_active;
assign rf1_active = layer_seq_mode && seq_active && (seq_stage == SEQ_STAGE_CONV1);

// Build SCU input tile from BankA (planar)
wire signed [DATA_W-1:0] rf1_input_tile [0:35];
genvar rf1i;
generate
	for (rf1i = 0; rf1i < 36; rf1i = rf1i + 1) begin : RF1_TILE
		assign rf1_input_tile[rf1i] = bank0_tile36[ic_idx][rf1i];
	end
endgenerate

reg rf1_clear;
reg rf1_en;

wire signed [DATA_W-1:0] rf1_OC0 [0:15];
wire signed [DATA_W-1:0] rf1_OC1 [0:15];
wire signed [DATA_W-1:0] rf1_OC2 [0:15];

scu_paper #(
	.A_bits(DATA_W),
	.W_bits(DATA_W),
	.I_bits(6),
	.ACC_bits(ACC_W)
) u_scu_rf1 (
	.clk(clk),
	.rst_n(rst_n),
	.mode(1'b1),
	.en(rf1_en),
	.clear(rf1_clear),
	.weights(scu_weights),
	.input_tile(rf1_input_tile),
	.indexes(scu_indexes),
	.OC0(rf1_OC0),
	.OC1(rf1_OC1),
	.OC2(rf1_OC2)
);

typedef enum reg [1:0] {RF1_IDLE=2'd0, RF1_CLEAR=2'd1, RF1_ACCUM=2'd2, RF1_WRITE=2'd3} rf1_state_t;
rf1_state_t rf1_state;

wire [7:0] rf1_base_oc;
assign rf1_base_oc = ob_idx * SCU_OUT_PAR;

integer rf1t;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rf1_state <= RF1_IDLE;
		rf1_clear <= 1'b0;
		rf1_en <= 1'b0;
		ob_idx <= 0;
		ic_idx <= 0;
		conv1_done_pulse <= 1'b0;
	end else begin
		conv1_done_pulse <= 1'b0;
		rf1_clear <= 1'b0;
		rf1_en <= 1'b0;

		if (!rf1_active) begin
			rf1_state <= RF1_IDLE;
			ob_idx <= 0;
			ic_idx <= 0;
		end else begin
			case (rf1_state)
				RF1_IDLE: begin
					// Start a new output batch (k,k+1,k+2)
					rf1_state <= RF1_CLEAR;
					ic_idx <= 0;
				end

				RF1_CLEAR: begin
					// Clear SCU accumulators for this output batch
					rf1_clear <= 1'b1;
					rf1_state <= RF1_ACCUM;
					ic_idx <= 0;
				end

				RF1_ACCUM: begin
					// Accumulate over all 32 input channels
					rf1_en <= 1'b1;
					if (ic_idx == (FUSED_CH-1)) begin
						rf1_state <= RF1_WRITE;
					end else begin
						ic_idx <= ic_idx + 1'b1;
					end
				end

				RF1_WRITE: begin
					// Store the resulting tiles into BankB at output channels k..k+2
					for (rf1t = 0; rf1t < 16; rf1t = rf1t + 1) begin
						if ((rf1_base_oc + 0) < FUSED_CH) bank1_tile36[rf1_base_oc + 0][rf1t] <= rf1_OC0[rf1t];
						if ((rf1_base_oc + 1) < FUSED_CH) bank1_tile36[rf1_base_oc + 1][rf1t] <= rf1_OC1[rf1t];
						if ((rf1_base_oc + 2) < FUSED_CH) bank1_tile36[rf1_base_oc + 2][rf1t] <= rf1_OC2[rf1t];
					end
					for (rf1t = 16; rf1t < 36; rf1t = rf1t + 1) begin
						if ((rf1_base_oc + 0) < FUSED_CH) bank1_tile36[rf1_base_oc + 0][rf1t] <= '0;
						if ((rf1_base_oc + 1) < FUSED_CH) bank1_tile36[rf1_base_oc + 1][rf1t] <= '0;
						if ((rf1_base_oc + 2) < FUSED_CH) bank1_tile36[rf1_base_oc + 2][rf1t] <= '0;
					end

					ic_idx <= 0;
					if (ob_idx == (CHANNEL_LOOP_COUNT-1)) begin
						conv1_done_pulse <= 1'b1;
						ob_idx <= 0;
						rf1_state <= RF1_IDLE;
					end else begin
						ob_idx <= ob_idx + 1'b1;
						rf1_state <= RF1_CLEAR;
					end
				end
			endcase
		end
	end
end

//==============================================================================
// RFConv0 standard convolution engine
// - Loads 32 input-channel tiles via PreTA into bank_in_tile36.
// - Output-stationary: for each output-batch (k,k+1,k+2), accumulate over ic=0..31.
// - Write-back: store 3 output tiles to bank0_tile36.
//==============================================================================

wire rf0_active;
assign rf0_active = layer_seq_mode && seq_active && (seq_stage == SEQ_STAGE_CONV0) && rf0_inputs_ready;

wire signed [DATA_W-1:0] rf0_input_tile [0:35];
genvar rf0i;
generate
	for (rf0i = 0; rf0i < 36; rf0i = rf0i + 1) begin : RF0_TILE
		assign rf0_input_tile[rf0i] = bank_in_tile36[ic0_idx][rf0i];
	end
endgenerate

reg rf0_clear;
reg rf0_en;

wire signed [DATA_W-1:0] rf0_OC0 [0:15];
wire signed [DATA_W-1:0] rf0_OC1 [0:15];
wire signed [DATA_W-1:0] rf0_OC2 [0:15];

scu_paper #(
	.A_bits(DATA_W),
	.W_bits(DATA_W),
	.I_bits(6),
	.ACC_bits(ACC_W)
) u_scu_rf0 (
	.clk(clk),
	.rst_n(rst_n),
	.mode(1'b1),
	.en(rf0_en),
	.clear(rf0_clear),
	.weights(scu_weights),
	.input_tile(rf0_input_tile),
	.indexes(scu_indexes),
	.OC0(rf0_OC0),
	.OC1(rf0_OC1),
	.OC2(rf0_OC2)
);

typedef enum reg [1:0] {RF0_IDLE=2'd0, RF0_CLEAR=2'd1, RF0_ACCUM=2'd2, RF0_WRITE=2'd3} rf0_state_t;
rf0_state_t rf0_state;

wire [7:0] rf0_base_oc;
assign rf0_base_oc = ob0_idx * SCU_OUT_PAR;

integer rf0t;
always @(posedge clk or negedge rst_n) begin
	if (!rst_n) begin
		rf0_state <= RF0_IDLE;
		rf0_clear <= 1'b0;
		rf0_en <= 1'b0;
		ob0_idx <= 0;
		ic0_idx <= 0;
		conv0_done_pulse <= 1'b0;
	end else begin
		conv0_done_pulse <= 1'b0;
		rf0_clear <= 1'b0;
		rf0_en <= 1'b0;

		if (!rf0_active) begin
			rf0_state <= RF0_IDLE;
			ob0_idx <= 0;
			ic0_idx <= 0;
		end else begin
			case (rf0_state)
				RF0_IDLE: begin
					rf0_state <= RF0_CLEAR;
					ic0_idx <= 0;
				end

				RF0_CLEAR: begin
					rf0_clear <= 1'b1;
					rf0_state <= RF0_ACCUM;
					ic0_idx <= 0;
				end

				RF0_ACCUM: begin
					rf0_en <= 1'b1;
					if (ic0_idx == (FUSED_CH-1)) begin
						rf0_state <= RF0_WRITE;
					end else begin
						ic0_idx <= ic0_idx + 1'b1;
					end
				end

				RF0_WRITE: begin
					for (rf0t = 0; rf0t < 16; rf0t = rf0t + 1) begin
						if ((rf0_base_oc + 0) < FUSED_CH) bank0_tile36[rf0_base_oc + 0][rf0t] <= rf0_OC0[rf0t];
						if ((rf0_base_oc + 1) < FUSED_CH) bank0_tile36[rf0_base_oc + 1][rf0t] <= rf0_OC1[rf0t];
						if ((rf0_base_oc + 2) < FUSED_CH) bank0_tile36[rf0_base_oc + 2][rf0t] <= rf0_OC2[rf0t];
					end
					for (rf0t = 16; rf0t < 36; rf0t = rf0t + 1) begin
						if ((rf0_base_oc + 0) < FUSED_CH) bank0_tile36[rf0_base_oc + 0][rf0t] <= '0;
						if ((rf0_base_oc + 1) < FUSED_CH) bank0_tile36[rf0_base_oc + 1][rf0t] <= '0;
						if ((rf0_base_oc + 2) < FUSED_CH) bank0_tile36[rf0_base_oc + 2][rf0t] <= '0;
					end

					ic0_idx <= 0;
					if (ob0_idx == (CHANNEL_LOOP_COUNT-1)) begin
						conv0_done_pulse <= 1'b1;
						ob0_idx <= 0;
						rf0_state <= RF0_IDLE;
					end else begin
						ob0_idx <= ob0_idx + 1'b1;
						rf0_state <= RF0_CLEAR;
					end
				end
			endcase
		end
	end
end

// Deconvolution path: 6x6 SCA
wire sca_valid_deconv;
wire signed [ACC_W-1:0] sca_out_deconv [0:5][0:5];
wire [WEIGHT_ADDR_W-1:0] sca_weight_addr_deconv;
wire [INDEX_ADDR_W-1:0] sca_index_addr_deconv;

// Second deconv channel (dy) for motion vectors
wire sca_valid_deconv_dy;
wire signed [ACC_W-1:0] sca_out_deconv_dy [0:5][0:5];
wire [WEIGHT_ADDR_W-1:0] sca_weight_addr_deconv_dy;
wire [INDEX_ADDR_W-1:0] sca_index_addr_deconv_dy;

// Need 6x6 weight data for deconv - extend from 4x4 (pad with zeros)
reg [INDEX_ADDR_W-1:0] index_data_6x6 [0:5][0:5];
reg [INDEX_ADDR_W-1:0] index_data_6x6_dy [0:5][0:5];
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
reg signed [DATA_W-1:0] weight_data_6x6_dy [0:5][0:5];
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

always @(*) begin
    for (idi = 0; idi < 6; idi = idi + 1) begin
        for (idj = 0; idj < 6; idj = idj + 1) begin
            if (idi < 4 && idj < 4)
                index_data_6x6_dy[idi][idj] = index_data_dy[idi][idj];
            else
                index_data_6x6_dy[idi][idj] = 0;
        end
    end
end

always @(*) begin
    for (wi = 0; wi < 6; wi = wi + 1) begin
        for (wj = 0; wj < 6; wj = wj + 1) begin
            if (wi < 4 && wj < 4)
                weight_data_6x6_dy[wi][wj] = weight_data_dy[wi][wj];
            else
                weight_data_6x6_dy[wi][wj] = 0;
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

// Deconv uses the same generalized SCA module but in fallback (dense/index) mode.
sca_conv_paper #(
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
	 .use_list_mode(1'b0),
	 .y_in(sca_in_deconv),
	 .weight_data(weight_data_6x6),
	 .index_data(index_data_6x6),
	 .weights18(scu_weights),
	 .indexes18(scu_indexes),
	 .weight_addr(sca_weight_addr_deconv),
	 .index_addr(sca_index_addr_deconv),
	 .valid_out(sca_valid_deconv),
	 .u_out(sca_out_deconv),
	 .u0_out(),
	 .u1_out(),
	 .u2_out()
);

sca_conv_paper #(
	 .DATA_W(DATA_W),
	 .ACC_W(ACC_W),
	 .N_ROWS(6),
	 .N_COLS(6),
	 .WEIGHT_ADDR_W(WEIGHT_ADDR_W),
	 .INDEX_ADDR_W(INDEX_ADDR_W)
) u_sca_deconv_dy (
	 .clk(clk),
	 .rst_n(rst_n),
	 .valid_in(preta_valid_deconv),
	 .use_list_mode(1'b0),
	 .y_in(sca_in_deconv),
	 .weight_data(weight_data_6x6_dy),
	 .index_data(index_data_6x6_dy),
	 .weights18(scu_weights),
	 .indexes18(scu_indexes),
	 .weight_addr(sca_weight_addr_deconv_dy),
	 .index_addr(sca_index_addr_deconv_dy),
	 .valid_out(sca_valid_deconv_dy),
	 .u_out(sca_out_deconv_dy),
	 .u0_out(),
	 .u1_out(),
	 .u2_out()
);

// Mux weight and index addresses based on mode
assign weight_addr = (layer_seq_mode && seq_active) ? seq_weight_base : (conv_mode ? sca_weight_addr_conv : sca_weight_addr_deconv);
assign index_addr  = (layer_seq_mode && seq_active) ? seq_weight_base : (conv_mode ? sca_index_addr_conv  : sca_index_addr_deconv);

// Simple conv address stepping (base address for scu_weights/scu_indexes)
// In this repo, weight_addr is used as a base pointer. Increment per accepted conv tile.
always @(posedge clk or negedge rst_n) begin
	 if (!rst_n) begin
	 	 sca_weight_addr_conv <= '0;
	 	 sca_index_addr_conv  <= '0;
	 end else begin
	 	 if (!layer_seq_mode && preta_valid_conv) begin
	 	 	 sca_weight_addr_conv <= sca_weight_addr_conv + 18; // 18 words per SCU list
	 	 	 sca_index_addr_conv  <= sca_index_addr_conv  + 18;
	 	 end
	 end
end

// ====== PosTA Stage ======
// Convolution path: 4x4 -> 2x2
wire posta_valid_conv;
wire signed [ACC_W-1:0] posta_out_conv [0:1][0:1];

wire posta_valid_conv1;
wire signed [ACC_W-1:0] posta_out_conv1 [0:1][0:1];

wire posta_valid_conv2;
wire signed [ACC_W-1:0] posta_out_conv2 [0:1][0:1];

reg signed [DATA_W-1:0] posta_in_conv [0:3][0:3];
reg signed [DATA_W-1:0] posta_in_conv1 [0:3][0:3];
reg signed [DATA_W-1:0] posta_in_conv2 [0:3][0:3];
integer pi, pj;
always @(*) begin
    for (pi = 0; pi < 4; pi = pi + 1) begin
        for (pj = 0; pj < 4; pj = pj + 1) begin
            // Saturation
	 	 	 if (sca_out_conv0[pi][pj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                posta_in_conv[pi][pj] = {1'b0, {(DATA_W-1){1'b1}}};
	 	 	 else if (sca_out_conv0[pi][pj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                posta_in_conv[pi][pj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
	 	 	 	 posta_in_conv[pi][pj] = sca_out_conv0[pi][pj][DATA_W-1:0];

	 	 	 if (sca_out_conv1[pi][pj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
	 	 	 	 posta_in_conv1[pi][pj] = {1'b0, {(DATA_W-1){1'b1}}};
	 	 	 else if (sca_out_conv1[pi][pj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
	 	 	 	 posta_in_conv1[pi][pj] = {1'b1, {(DATA_W-1){1'b0}}};
	 	 	 else
	 	 	 	 posta_in_conv1[pi][pj] = sca_out_conv1[pi][pj][DATA_W-1:0];

	 	 	 if (sca_out_conv2[pi][pj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
	 	 	 	 posta_in_conv2[pi][pj] = {1'b0, {(DATA_W-1){1'b1}}};
	 	 	 else if (sca_out_conv2[pi][pj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
	 	 	 	 posta_in_conv2[pi][pj] = {1'b1, {(DATA_W-1){1'b0}}};
	 	 	 else
	 	 	 	 posta_in_conv2[pi][pj] = sca_out_conv2[pi][pj][DATA_W-1:0];
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

posta_conv #(
	 .DATA_W(DATA_W),
	 .ACC_W(ACC_W)
) u_posta_conv1 (
	 .clk(clk),
	 .rst_n(rst_n),
	 .valid_in(sca_valid_conv),
	 .patch_in(posta_in_conv1),
	 .valid_out(posta_valid_conv1),
	 .patch_out(posta_out_conv1)
);

posta_conv #(
	 .DATA_W(DATA_W),
	 .ACC_W(ACC_W)
) u_posta_conv2 (
	 .clk(clk),
	 .rst_n(rst_n),
	 .valid_in(sca_valid_conv),
	 .patch_in(posta_in_conv2),
	 .valid_out(posta_valid_conv2),
	 .patch_out(posta_out_conv2)
);

// Deconvolution path: 6x6 -> 4x4
wire posta_valid_deconv;
wire signed [ACC_W-1:0] posta_out_deconv [0:3][0:3];

wire posta_valid_deconv_dy;
wire signed [ACC_W-1:0] posta_out_deconv_dy [0:3][0:3];

reg signed [DATA_W-1:0] posta_in_deconv [0:5][0:5];
reg signed [DATA_W-1:0] posta_in_deconv_dy [0:5][0:5];
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

always @(*) begin
    for (pdi = 0; pdi < 6; pdi = pdi + 1) begin
        for (pdj = 0; pdj < 6; pdj = pdj + 1) begin
            // Saturation
            if (sca_out_deconv_dy[pdi][pdj] > $signed({1'b0, {(DATA_W-1){1'b1}}}))
                posta_in_deconv_dy[pdi][pdj] = {1'b0, {(DATA_W-1){1'b1}}};
            else if (sca_out_deconv_dy[pdi][pdj] < $signed({1'b1, {(DATA_W-1){1'b0}}}))
                posta_in_deconv_dy[pdi][pdj] = {1'b1, {(DATA_W-1){1'b0}}};
            else
                posta_in_deconv_dy[pdi][pdj] = sca_out_deconv_dy[pdi][pdj][DATA_W-1:0];
        end
    end
end

posta_deconv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_posta_deconv (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sca_valid_deconv && sca_valid_deconv_dy),
    .patch_in(posta_in_deconv),
    .valid_out(posta_valid_deconv),
    .patch_out(posta_out_deconv)
);

posta_deconv #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W)
) u_posta_deconv_dy (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sca_valid_deconv_dy),
    .patch_in(posta_in_deconv_dy),
    .valid_out(posta_valid_deconv_dy),
    .patch_out(posta_out_deconv_dy)
);

// Mux PosTA outputs based on mode
wire posta_valid;
assign posta_valid = op_conv_mode ? posta_valid_conv : (posta_valid_deconv && posta_valid_deconv_dy);

wire tile_done_pulse;
wire external_launch;
assign tile_done_pulse = posta_valid && !serializing;
assign external_launch = emit_external && tile_done_pulse;

// ====== Reshuffle Network (between PosTA and output buffer/QMU feed) ======
// Paper Fig. 3(b) places a reshuffle network after PosT to deal with overlapped tiles.
// In this streaming SFTM, we model it as a deterministic row-rotation per tile.
reg [1:0] reshuffle_step;
wire signed [ACC_W-1:0] posta_deconv_reshuffled [0:3][0:3];
wire signed [ACC_W-1:0] posta_deconv_reshuffled_dy [0:3][0:3];

reshuffle_network #(
    .N(4),
    .WIDTH(ACC_W)
) u_reshuffle (
    .step(reshuffle_step),
    .in_patch(posta_out_deconv),
    .out_patch(posta_deconv_reshuffled)
);

reshuffle_network #(
    .N(4),
    .WIDTH(ACC_W)
) u_reshuffle_dy (
    .step(reshuffle_step),
    .in_patch(posta_out_deconv_dy),
    .out_patch(posta_deconv_reshuffled_dy)
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

wire [4:0] serialize_cnt_dy = serialize_cnt - 5'd16;

reg signed [ACC_W-1:0] post2_reg0 [0:1][0:1];
reg signed [ACC_W-1:0] post2_reg1 [0:1][0:1];
reg signed [ACC_W-1:0] post2_reg2 [0:1][0:1];
reg signed [ACC_W-1:0] post4_reg [0:3][0:3];
reg signed [ACC_W-1:0] post4_reg_dy [0:3][0:3];
integer sri, srj;

// Sequencer FSM
always @(posedge clk or negedge rst_n) begin
	 if (!rst_n) begin
		 seq_active <= 1'b0;
		 seq_stage <= SEQ_STAGE_CONV0;
		 seq_load_internal <= 1'b0;
		 seq_enter_conv1 <= 1'b0;
		 seq_enter_deconv <= 1'b0;
	 end else begin
		 seq_load_internal <= 1'b0;
		 seq_enter_conv1 <= 1'b0;
		 seq_enter_deconv <= 1'b0;

		 if (!layer_seq_mode) begin
			 seq_active <= 1'b0;
			 seq_stage <= SEQ_STAGE_CONV0;
		 end else begin
			 if (start && !seq_active) begin
				 seq_active <= 1'b1;
				 seq_stage <= SEQ_STAGE_CONV0;
			 end

			 // RFConv0/RFConv1 complete after CHANNEL_LOOP_COUNT passes stored.
			 if (seq_active && conv_stage_done_pulse) begin
				 if (seq_stage == SEQ_STAGE_CONV0) begin
					 seq_stage <= SEQ_STAGE_CONV1;
					 seq_enter_conv1 <= 1'b1;
				 end else if (seq_stage == SEQ_STAGE_CONV1) begin
					 seq_stage <= SEQ_STAGE_DECONV;
					 seq_enter_deconv <= 1'b1;
					 seq_load_internal <= 1'b1;
				 end
			 end

			 if (seq_active && seq_is_final && seq_finish_pulse) begin
				 seq_active <= 1'b0;
				 seq_stage <= SEQ_STAGE_CONV0;
			 end
		 end
	 end
end

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
	 	 	 	 begin
	 	 	 	 	 post2_reg0[sri][srj] <= 0;
	 	 	 	 	 post2_reg1[sri][srj] <= 0;
	 	 	 	 	 post2_reg2[sri][srj] <= 0;
	 	 	 	 end
        for (sri = 0; sri < 4; sri = sri + 1)
            for (srj = 0; srj < 4; srj = srj + 1)
                post4_reg[sri][srj] <= 0;
        for (sri = 0; sri < 4; sri = sri + 1)
            for (srj = 0; srj < 4; srj = srj + 1)
                post4_reg_dy[sri][srj] <= 0;
    end else begin
        qmu_in_valid <= 1'b0;

        // Capture a completed PosTA tile into local regs (acts like an output buffer)
	 	 if (posta_valid && !serializing) begin
	           if (op_conv_mode) begin
                for (sri = 0; sri < 2; sri = sri + 1)
                    for (srj = 0; srj < 2; srj = srj + 1)
	 	 	 	 	 begin
	 	 	 	 	 	 post2_reg0[sri][srj] <= posta_out_conv[sri][srj];
	 	 	 	 	 	 post2_reg1[sri][srj] <= posta_out_conv1[sri][srj];
	 	 	 	 	 	 post2_reg2[sri][srj] <= posta_out_conv2[sri][srj];
	 	 	 	 	 end


            end else begin
						for (sri = 0; sri < 4; sri = sri + 1) begin
							for (srj = 0; srj < 4; srj = srj + 1) begin
								post4_reg[sri][srj] <= posta_deconv_reshuffled[sri][srj];
								post4_reg_dy[sri][srj] <= posta_deconv_reshuffled_dy[sri][srj];
							end
						end
                reshuffle_step <= reshuffle_step + 1'b1; // advance per accepted tile
            end

				 if (emit_external) begin
	 	 	 	 serializing <= 1'b1;
	           	 serialize_cnt <= 0;
		       	 serialize_max <= op_conv_mode ? 5'd11 : 5'd31; // conv: 12, deconv: 2 channels * 16 = 32
				 end
        end

        // Stream the captured tile into QMU
        if (serializing) begin
            qmu_in_valid <= 1'b1;
	           if (op_conv_mode) begin
	 	 	 	 // 3 channels x 2x2, order: ch (cnt/4), within-ch sample (cnt%4)
	 	 	 	 case (serialize_cnt[4:2])
	 	 	 	 	 3'd0: qmu_in <= post2_reg0[serialize_cnt[1]][serialize_cnt[0]][DATA_W-1:0];
	 	 	 	 	 3'd1: qmu_in <= post2_reg1[serialize_cnt[1]][serialize_cnt[0]][DATA_W-1:0];
	 	 	 	 	 default: qmu_in <= post2_reg2[serialize_cnt[1]][serialize_cnt[0]][DATA_W-1:0];
	 	 	 	 endcase
            end else begin
                // 2 channels x 4x4: dx (0..15) then dy (16..31)
                if (serialize_cnt < 5'd16) begin
                    qmu_in <= post4_reg[serialize_cnt[4:2]][serialize_cnt[1:0]][DATA_W-1:0];
                end else begin
					qmu_in <= post4_reg_dy[serialize_cnt_dy[4:2]][serialize_cnt_dy[1:0]][DATA_W-1:0];
                end
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
		 seq_finish_pulse <= 1'b0;
    end else begin
        group_done <= 1'b0;
		 seq_finish_pulse <= 1'b0;
        
		 if (!processing) begin
			 if (!layer_seq_mode) begin
				 if (start && emit_external) begin
					 processing <= 1'b1;
					 group_valid <= 1'b1;
					 output_cnt <= 0;
					 // Conv outputs 12 samples (3 channels x 2x2), Deconv outputs 32 samples (dx+dy, 2 channels x 4x4)
					 output_max <= op_conv_mode ? 5'd11 : 5'd31;
				 end
			 end else begin
				 // In fusion mode, only the final stage is allowed to create an external group.
				 if (external_launch) begin
					 processing <= 1'b1;
					 group_valid <= 1'b1;
					 output_cnt <= 0;
					 output_max <= op_conv_mode ? 5'd11 : 5'd31;
				 end
			 end
		 end
        
	       if (emit_external && bypass_mode && input_valid) begin
            // Bypass: pass through directly
            group_data <= input_data;
            group_data_valid <= 1'b1;
            output_cnt <= output_cnt + 1;
            if (output_cnt == output_max) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                output_cnt <= 0;
				 if (layer_seq_mode) seq_finish_pulse <= 1'b1;
            end
	       end else if (emit_external && qmu_valid) begin
            // Normal mode: output from QMU
            group_data <= qmu_out;
            group_data_valid <= 1'b1;
            output_cnt <= output_cnt + 1;
            if (output_cnt == output_max) begin
                group_done <= 1'b1;
                processing <= 1'b0;
                group_valid <= 1'b0;
                output_cnt <= 0;
				 if (layer_seq_mode) seq_finish_pulse <= 1'b1;
            end
        end else begin
            group_data_valid <= 1'b0;
        end
    end
end

endmodule

