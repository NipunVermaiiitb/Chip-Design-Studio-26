// vcnpu_top.v
// Top-level for VCNPU + Group-Synchronized Forwarding integration
// Simplified for clarity: instantiate SFTM, Group FIFO, DPM, SplitPrefetcher, Global Controller

`timescale 1ns/1ps
module vcnpu_top #(
    parameter DATA_W = 16,
    parameter N_CH   = 36,
    parameter GROUP_ROWS = 4,
    parameter DEPTH_GROUPS = 2
)(
    input  wire clk,
    input  wire rst_n,

    // External DRAM interface (simplified)
    output wire dram_req,
    output wire [31:0] dram_addr,
    output wire [15:0] dram_len,    // length in rows/words
    input  wire        dram_ack,
    input  wire        dram_data_valid,
    input  wire [DATA_W-1:0] dram_data_in,

    // Control/status
    input  wire start,    // start decode
    output wire busy,
    output wire error
);

localparam FIFO_DEPTH_ROWS = GROUP_ROWS * DEPTH_GROUPS;

// Internal wires
wire sftm_group_done;
wire sftm_valid_group;
wire [DATA_W-1:0] sftm_data;
wire sftm_data_valid;

wire fifo_push, fifo_pop;
wire fifo_full, fifo_empty;
wire [DATA_W-1:0] fifo_dout;
wire fifo_dout_valid;

wire credit_available;
wire dpm_start_group;
wire bypass_mode_en;

// Global controller signals
wire global_start;
assign global_start = start;

// Instantiate SFTM (sparse fast transform module)
sftm #(
    .DATA_W(DATA_W),
    .N_CH(N_CH),
    .GROUP_ROWS(GROUP_ROWS)
) u_sftm (
    .clk(clk),
    .rst_n(rst_n),
    .start(global_start),
    // output group handshake
    .group_valid(sftm_valid_group),
    .group_done(sftm_group_done),
    .group_data(sftm_data),
    .group_data_valid(sftm_data_valid),
    // control from global controller
    .bypass_mode(bypass_mode_en)
);

// Group-synchronized FIFO (multi-banked simplified)
group_sync_fifo #(
    .DATA_W(DATA_W),
    .GROUP_ROWS(GROUP_ROWS),
    .DEPTH_GROUPS(DEPTH_GROUPS)
) u_gsfifo (
    .clk(clk),
    .rst_n(rst_n),
    // write side (SFTM)
    .wr_en(sftm_data_valid),
    .wr_data(sftm_data),
    .wr_group_valid(sftm_valid_group),
    .group_done(sftm_group_done),
    // read side (DPM)
    .rd_en(fifo_pop),
    .rd_data(fifo_dout),
    .rd_data_valid(fifo_dout_valid),
    // status
    .full(fifo_full),
    .empty(fifo_empty),
    // credits interface
    .credit_available(credit_available),
    .bypass_mode(bypass_mode_en),
    .error(error)
);

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

// Split-prefetcher issues DRAM reads for Ft-1 tiles when groups complete
split_prefetcher #(
    .ADDR_WIDTH(32)
) u_prefetch (
    .clk(clk),
    .rst_n(rst_n),
    .group_done(sftm_group_done),
    .issue_req(dram_req),
    .addr(dram_addr),
    .len(dram_len),
    .dram_ack(dram_ack)
);

// DPM module (consumes fifo data and reference pixels fetched by prefetcher)
dpm #(
    .DATA_W(DATA_W),
    .N_CH(N_CH),
    .GROUP_ROWS(GROUP_ROWS)
) u_dpm (
    .clk(clk),
    .rst_n(rst_n),
    .start(1'b1),
    .fifo_data(fifo_dout),
    .fifo_data_valid(fifo_dout_valid),
    .fifo_pop(fifo_pop),
    .bypass_mode(bypass_mode_en)
);

// Global controller (coarse)
global_controller #(
    .GROUP_ROWS(GROUP_ROWS)
) u_glob (
    .clk(clk),
    .rst_n(rst_n),
    .start(global_start),
    .sftm_busy(), .dpm_busy(), .fifo_full(fifo_full),
    .bypass_mode(bypass_mode_en),
    .busy(busy)
);

endmodule
