//====================================================
// VCNPU Proposed Architecture - Top Level
//====================================================

module vcnpu_proposed #(
    parameter integer BANKS = 2,
    parameter integer GROUP_SLOTS = 2,
    parameter integer FRAME_COLS = 64,
    parameter integer FRAME_ROWS = 32,
    parameter integer ROWS_PER_GROUP = 4
)(
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output wire done
);

    // ------------------------------------------------
    // Producer → FIFO
    // ------------------------------------------------
    wire prod_valid;
    wire [15:0] prod_gid;
    wire [15:0] prod_row_group;
    wire [15:0] prod_col_tile;
    wire [15:0] prod_col_start;
    wire [15:0] prod_col_end;

    producer_sftm #(
        .FRAME_COLS(FRAME_COLS),
        .FRAME_ROWS(FRAME_ROWS),
        .ROWS_PER_GROUP(ROWS_PER_GROUP),
        .BASE_PERIOD(20),
        .JITTER(0)
    ) u_producer (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .tile_columns(16),
        .groups_total(8),
        .tile_valid(prod_valid),
        .gid(prod_gid),
        .row_group_idx(prod_row_group),
        .col_tile_idx(prod_col_tile),
        .col_start(prod_col_start),
        .col_end(prod_col_end)
    );

    // ------------------------------------------------
    // Banked Group FIFO
    // ------------------------------------------------
    wire fifo_push_ready;
    wire fifo_pop_valid;
    wire [15:0] fifo_pop_gid;
    wire [2:0] fifo_occupancy;

    banked_group_fifo #(
        .BANKS(BANKS),
        .GROUP_SLOTS(GROUP_SLOTS),
        .GID_WIDTH(16)
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .push_valid(prod_valid),
        .push_gid(prod_gid),
        .push_ready(fifo_push_ready),
        .push_bank(),
        .push_slot(),
        .peek_valid(),
        .peek_gid(),
        .pop_ready(consumer_ready),
        .pop_valid(fifo_pop_valid),
        .pop_gid(fifo_pop_gid),
        .occupancy(fifo_occupancy),
        .overflow()
    );

    // ------------------------------------------------
    // Address Generator (reference only for demo)
    // ------------------------------------------------
    wire [31:0] addr_base;
    wire [31:0] addr_len;

    addr_gen u_addr (
        .frame_base_addr(32'h1000_0000),
        .frame_stride_bytes(FRAME_COLS * 2),
        .bytes_per_pixel(2),
        .tile_row_start(prod_row_group * ROWS_PER_GROUP),
        .tile_col_start(prod_col_start),
        .tile_rows(ROWS_PER_GROUP),
        .tile_cols(prod_col_end - prod_col_start + 1),
        .halo(1),
        .is_reference(1'b1),
        .base_addr(addr_base),
        .length_bytes(addr_len)
    );

    // ------------------------------------------------
    // Split Prefetcher
    // ------------------------------------------------
    wire dma_issue_valid;
    wire [31:0] dma_issue_base;
    wire [31:0] dma_issue_len;
    wire dma_done_valid;
    wire [7:0] dma_done_tag;
    wire tile_ready_valid;
    wire [15:0] tile_ready_gid;

    split_prefetcher u_prefetch (
        .clk(clk),
        .rst_n(rst_n),
        .req_valid(prod_valid),
        .req_base(addr_base),
        .req_len(addr_len),
        .req_gid(prod_gid),
        .dma_issue_valid(dma_issue_valid),
        .dma_issue_base(dma_issue_base),
        .dma_issue_len(dma_issue_len),
        .dma_issue_ready(1'b1),
        .dma_done_valid(dma_done_valid),
        .dma_done_tag(dma_done_tag),
        .tile_ready_valid(tile_ready_valid),
        .tile_ready_gid(tile_ready_gid)
    );

    // ------------------------------------------------
    // DMA Engine
    // ------------------------------------------------
    dma_engine #(
        .DRAM_LATENCY(10),
        .BW_BYTES_PER_CYCLE(16),
        .MAX_OUTSTANDING(4)
    ) u_dma (
        .clk(clk),
        .rst_n(rst_n),
        .issue_valid(dma_issue_valid),
        .issue_base_addr(dma_issue_base),
        .issue_length(dma_issue_len),
        .issue_ready(),
        .issue_tag(),
        .done_valid(dma_done_valid),
        .done_tag(dma_done_tag),
        .outstanding_count()
    );

    // ------------------------------------------------
    // Consumer
    // ------------------------------------------------
    wire consumer_ready;

    consumer_dpm #(
        .FRAME_COLS(FRAME_COLS),
        .BASE_PERIOD(20),
        .JITTER(0)
    ) u_consumer (
        .clk(clk),
        .rst_n(rst_n),
        .start(start),
        .tile_columns(16),
        .consume_start(tile_ready_valid),
        .ready_to_consume(consumer_ready),
        .consumed_count()
    );

    assign done = (fifo_occupancy == 0) && !prod_valid;

endmodule
