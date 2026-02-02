// Module Interface Documentation
// Updated interfaces for completed modules

//==============================================================================
// 1. SCA (Sparse Computing Array) - NEW MODULE
//==============================================================================
module sca #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_ROWS = 4,
    parameter N_COLS = 4,
    parameter N_CH = 36,
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
// 2. SFTM (Sparse Fast Transform Module) - UPDATED
//==============================================================================
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
    
    // NEW: Input data stream (feature patches)
    input wire [DATA_W-1:0] input_data,
    input wire input_valid,
    
    // NEW: Operation mode
    input wire conv_mode,       // 1=conv, 0=deconv
    input wire [1:0] quality_mode,
    
    // NEW: Weight memory interface
    output wire [WEIGHT_ADDR_W-1:0] weight_addr,
    input wire signed [DATA_W-1:0] weight_data [0:3][0:3],
    
    // Outputs (unchanged)
    output reg group_valid,
    output reg group_done,
    output reg [DATA_W-1:0] group_data,
    output reg group_data_valid,
    input wire bypass_mode
);

//==============================================================================
// 3. DPM (Deformable Processing Module) - UPDATED
//==============================================================================
module dpm #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4,
    parameter KERNEL_SIZE = 3,
    parameter REF_BUF_SIZE = 16
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    
    // Input from FIFO (transformed features and offsets)
    input wire [DATA_W-1:0] fifo_data,
    input wire fifo_data_valid,
    output reg fifo_pop,
    
    // NEW: Reference frame data from prefetcher
    input wire [DATA_W-1:0] ref_data,
    input wire ref_data_valid,
    
    // Control
    input wire bypass_mode,
    
    // NEW: Output (deformable convolution result)
    output reg [DATA_W-1:0] dpm_out,
    output reg dpm_out_valid
);

//==============================================================================
// 4. SPLIT_PREFETCHER - UPDATED
//==============================================================================
module split_prefetcher #(
    parameter ADDR_WIDTH = 32,
    parameter FRAME_WIDTH = 1920,
    parameter FRAME_HEIGHT = 1080,
    parameter TILE_SIZE = 16,
    parameter GROUP_ROWS = 4
)(
    input  wire clk,
    input  wire rst_n,
    
    // NEW: Configuration
    input  wire [15:0] frame_width,
    input  wire [15:0] frame_height,
    input  wire [ADDR_WIDTH-1:0] ref_frame_base_addr,
    
    // Control
    input  wire group_done,
    input  wire [15:0] group_x,     // NEW: Group position X
    input  wire [15:0] group_y,     // NEW: Group position Y
    
    // DRAM interface
    output reg  issue_req,
    output reg  [ADDR_WIDTH-1:0] addr,
    output reg  [15:0] len,
    input  wire dram_ack,
    
    // NEW: Status
    output wire busy
);

//==============================================================================
// 5. GLOBAL_CONTROLLER - UPDATED
//==============================================================================
module global_controller #(
    parameter GROUP_ROWS = 4,
    parameter MAX_CREDITS = 2,
    parameter FIFO_DEPTH = 8
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    
    // NEW: Status inputs from modules
    input wire sftm_group_done,
    input wire dpm_processing,
    input wire fifo_full,
    input wire fifo_empty,
    input wire credit_available,
    input wire prefetch_busy,
    input wire [3:0] fifo_count,

    // Consumer drain markers (for group-atomic draining)
    input wire drain_word,
    input wire drain_last,
    
    // NEW: Control outputs
    output reg sftm_enable,
    output reg dpm_enable,
    output reg bypass_mode,
    output reg prefetch_enable,
    
    // NEW: Status outputs
    output reg busy,
    output reg error,
    output reg [1:0] system_state
);
