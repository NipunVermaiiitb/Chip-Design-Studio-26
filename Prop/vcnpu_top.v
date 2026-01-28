// vcnpu_top.v
// Top-level for VCNPU + Group-Synchronized Forwarding integration
// Complete integration with SFTM pipeline, DPM deformable conv, smart prefetcher, and advanced controller

`timescale 1ns/1ps
module vcnpu_top #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_CH   = 36,
    parameter GROUP_ROWS = 4,
    parameter DEPTH_GROUPS = 2,
    parameter WEIGHT_ADDR_W = 12,
    parameter WEIGHT_MEM_SIZE = 4096,
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter TILE_SIZE = 16
)(
    input  wire clk,
    input  wire rst_n,

    // Configuration inputs (NEW)
    input  wire [15:0] frame_width,
    input  wire [15:0] frame_height,
    input  wire [31:0] ref_frame_base_addr,
    input  wire conv_mode,           // 1=conv, 0=deconv
    input  wire [1:0] quality_mode,  // Quality selection
    
    // Input data stream (NEW)
    input  wire [DATA_W-1:0] input_data,
    input  wire input_valid,

    // External DRAM interface
    output wire dram_req,
    output wire [31:0] dram_addr,
    output wire [15:0] dram_len,
    input  wire dram_ack,
    input  wire dram_data_valid,
    input  wire [DATA_W-1:0] dram_data_in,

    // Weight loading interface (NEW)
    input  wire weight_load_en,
    input  wire [WEIGHT_ADDR_W-1:0] weight_load_addr,
    input  wire [DATA_W-1:0] weight_load_data,

    // Control/status
    input  wire start,
    output wire busy,
    output wire error,
    
    // Output stream (NEW)
    output wire [DATA_W-1:0] output_data,
    output wire output_valid,
    output wire [1:0] system_state
);


localparam FIFO_DEPTH_ROWS = GROUP_ROWS * DEPTH_GROUPS;

//==============================================================================
// Weight Memory
//==============================================================================
reg [DATA_W-1:0] weight_memory [0:WEIGHT_MEM_SIZE-1];
wire [WEIGHT_ADDR_W-1:0] weight_addr;
wire signed [DATA_W-1:0] weight_data [0:3][0:3];

// Weight loading logic
integer w_i;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (w_i = 0; w_i < WEIGHT_MEM_SIZE; w_i = w_i + 1)
            weight_memory[w_i] <= 0;
    end else if (weight_load_en) begin
        weight_memory[weight_load_addr] <= weight_load_data;
    end
end

// Weight data array generation for SFTM
genvar wi, wj;
generate
    for (wi = 0; wi < 4; wi = wi + 1) begin : weight_row
        for (wj = 0; wj < 4; wj = wj + 1) begin : weight_col
            assign weight_data[wi][wj] = weight_memory[weight_addr + wi*4 + wj];
        end
    end
endgenerate

//==============================================================================
// Group Position Tracking
//==============================================================================
reg [15:0] current_group_x;
reg [15:0] current_group_y;
wire [15:0] max_groups_x;
wire [15:0] max_groups_y;

assign max_groups_x = (frame_width + TILE_SIZE - 1) / TILE_SIZE;
assign max_groups_y = (frame_height + TILE_SIZE - 1) / TILE_SIZE;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_group_x <= 0;
        current_group_y <= 0;
    end else if (start && !busy) begin
        // Reset on new frame
        current_group_x <= 0;
        current_group_y <= 0;
    end else if (sftm_group_done) begin
        // Advance to next group (raster scan order)
        if (current_group_x == max_groups_x - 1) begin
            current_group_x <= 0;
            if (current_group_y == max_groups_y - 1) begin
                current_group_y <= 0;  // Wrap around (frame complete)
            end else begin
                current_group_y <= current_group_y + 1;
            end
        end else begin
            current_group_x <= current_group_x + 1;
        end
    end
end

//==============================================================================
// Internal Signals
//==============================================================================
// SFTM signals
wire sftm_group_done;
wire sftm_valid_group;
wire [DATA_W-1:0] sftm_data;
wire sftm_data_valid;
wire sftm_enable;

// FIFO signals
wire fifo_push, fifo_pop;
wire fifo_full, fifo_empty;
wire [DATA_W-1:0] fifo_dout;
wire fifo_dout_valid;
wire [4:0] fifo_count_internal;
wire [3:0] fifo_count;

// Credit system
wire credit_available;

// DPM signals
wire dpm_enable;
wire [DATA_W-1:0] dpm_out;
wire dpm_out_valid;
reg dpm_processing;

// Prefetcher signals
wire prefetch_enable;
wire prefetch_busy;

// Controller signals
wire bypass_mode_en;
wire controller_error;
wire controller_busy;

// Extract 4-bit count for controller
assign fifo_count = fifo_count_internal[3:0];

// Track DPM processing state
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        dpm_processing <= 0;
    else
        dpm_processing <= dpm_enable && !fifo_empty;
end

// Output assignments
assign output_data = dpm_out;
assign output_valid = dpm_out_valid;
assign error = controller_error;

//==============================================================================
// Module Instantiations
//==============================================================================

// Instantiate SFTM (Complete pipeline: PreTA->SCA->PosTA->QMU)
sftm #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .N_CH(N_CH),
    .GROUP_ROWS(GROUP_ROWS),
    .WEIGHT_ADDR_W(WEIGHT_ADDR_W)
) u_sftm (
    .clk(clk),
    .rst_n(rst_n),
    .start(sftm_enable),
    // Input stream
    .input_data(input_data),
    .input_valid(input_valid),
    // Mode control
    .conv_mode(conv_mode),
    .quality_mode(quality_mode),
    // Weight memory interface
    .weight_addr(weight_addr),
    .weight_data(weight_data),
    // Output group handshake
    .group_valid(sftm_valid_group),
    .group_done(sftm_group_done),
    .group_data(sftm_data),
    .group_data_valid(sftm_data_valid),
    // Control
    .bypass_mode(bypass_mode_en)
);


// Group-synchronized FIFO
group_sync_fifo #(
    .DATA_W(DATA_W),
    .GROUP_ROWS(GROUP_ROWS),
    .DEPTH_GROUPS(DEPTH_GROUPS)
) u_gsfifo (
    .clk(clk),
    .rst_n(rst_n),
    // Write side (SFTM)
    .wr_en(sftm_data_valid),
    .wr_data(sftm_data),
    .wr_group_valid(sftm_valid_group),
    .group_done(sftm_group_done),
    // Read side (DPM)
    .rd_en(fifo_pop),
    .rd_data(fifo_dout),
    .rd_data_valid(fifo_dout_valid),
    // Status
    .full(fifo_full),
    .empty(fifo_empty),
    // Credits interface
    .credit_available(credit_available),
    .bypass_mode(bypass_mode_en),
    .error()
);

// Extract count from FIFO for controller
assign fifo_count_internal = u_gsfifo.count;

// Credit-based FSM
credit_fsm #(
    .MAX_CREDITS(DEPTH_GROUPS)
) u_credit_fsm (
    .clk(clk),
    .rst_n(rst_n),
    .group_produced(sftm_group_done),
    .group_consumed(fifo_pop),
    .credit_available(credit_available)
);

// Split-prefetcher with address generation
split_prefetcher #(
    .ADDR_WIDTH(32),
    .FRAME_WIDTH(FRAME_WIDTH),
    .FRAME_HEIGHT(FRAME_HEIGHT),
    .TILE_SIZE(TILE_SIZE),
    .GROUP_ROWS(GROUP_ROWS)
) u_prefetch (
    .clk(clk),
    .rst_n(rst_n),
    // Configuration
    .frame_width(frame_width),
    .frame_height(frame_height),
    .ref_frame_base_addr(ref_frame_base_addr),
    // Control
    .group_done(sftm_group_done),
    .group_x(current_group_x),
    .group_y(current_group_y),
    // DRAM interface
    .issue_req(dram_req),
    .addr(dram_addr),
    .len(dram_len),
    .dram_ack(dram_ack),
    // Status
    .busy(prefetch_busy)
);

// DPM module with deformable convolution
dpm #(
    .DATA_W(DATA_W),
    .ACC_W(ACC_W),
    .N_CH(N_CH),
    .GROUP_ROWS(GROUP_ROWS),
    .KERNEL_SIZE(3),
    .REF_BUF_SIZE(16)
) u_dpm (
    .clk(clk),
    .rst_n(rst_n),
    .start(dpm_enable),
    // Input from FIFO
    .fifo_data(fifo_dout),
    .fifo_data_valid(fifo_dout_valid),
    .fifo_pop(fifo_pop),
    // Reference frame data
    .ref_data(dram_data_in),
    .ref_data_valid(dram_data_valid),
    // Control
    .bypass_mode(bypass_mode_en),
    // Output
    .dpm_out(dpm_out),
    .dpm_out_valid(dpm_out_valid)
);

// Global controller with advanced scheduling
global_controller #(
    .GROUP_ROWS(GROUP_ROWS),
    .MAX_CREDITS(DEPTH_GROUPS),
    .FIFO_DEPTH(GROUP_ROWS * DEPTH_GROUPS)
) u_glob (
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    // Status inputs
    .sftm_group_done(sftm_group_done),
    .dpm_processing(dpm_processing),
    .fifo_full(fifo_full),
    .fifo_empty(fifo_empty),
    .credit_available(credit_available),
    .prefetch_busy(prefetch_busy),
    .fifo_count(fifo_count),
    // Control outputs
    .sftm_enable(sftm_enable),
    .dpm_enable(dpm_enable),
    .bypass_mode(bypass_mode_en),
    .prefetch_enable(prefetch_enable),
    // Status outputs
    .busy(controller_busy),
    .error(controller_error),
    .system_state(system_state)
);

//==============================================================================
// Top-level output assignments
//==============================================================================
assign busy = controller_busy;
assign error = controller_error;

endmodule
