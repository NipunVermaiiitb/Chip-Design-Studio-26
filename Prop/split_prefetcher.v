//====================================================
// Split Prefetcher
//====================================================
// - Page-table based region tracking
// - Coalesces identical regions
// - Issues DMA requests
// - Wakes TileGroups on completion
//====================================================

module split_prefetcher #(
    parameter integer PT_ENTRIES = 8,
    parameter integer ADDR_WIDTH = 32,
    parameter integer LEN_WIDTH  = 32,
    parameter integer TAG_WIDTH  = 8,
    parameter integer GID_WIDTH  = 16
)(
    input  wire clk,
    input  wire rst_n,

    // New region request (from addr_gen)
    input  wire req_valid,
    input  wire [ADDR_WIDTH-1:0] req_base,
    input  wire [LEN_WIDTH-1:0]  req_len,
    input  wire [GID_WIDTH-1:0]  req_gid,

    // DMA interface
    output reg  dma_issue_valid,
    output reg  [ADDR_WIDTH-1:0] dma_issue_base,
    output reg  [LEN_WIDTH-1:0]  dma_issue_len,
    input  wire dma_issue_ready,
    input  wire dma_done_valid,
    input  wire [TAG_WIDTH-1:0] dma_done_tag,

    // TileGroup ready
    output reg  tile_ready_valid,
    output reg  [GID_WIDTH-1:0] tile_ready_gid
);

    // -------------------------
    // Page table
    // -------------------------
    reg pt_valid   [0:PT_ENTRIES-1];
    reg pt_issued  [0:PT_ENTRIES-1];
    reg [ADDR_WIDTH-1:0] pt_base [0:PT_ENTRIES-1];
    reg [LEN_WIDTH-1:0]  pt_len  [0:PT_ENTRIES-1];
    reg [TAG_WIDTH-1:0]  pt_tag  [0:PT_ENTRIES-1];
    reg [GID_WIDTH-1:0]  pt_gid  [0:PT_ENTRIES-1];

    integer i;
    integer free_idx;
    integer hit_idx;

    // -------------------------
    // Lookup
    // -------------------------
    always @(*) begin
        hit_idx  = -1;
        free_idx = -1;

        for (i = 0; i < PT_ENTRIES; i = i + 1) begin
            if (pt_valid[i]) begin
                if (pt_base[i] == req_base && pt_len[i] == req_len)
                    hit_idx = i;
            end else if (free_idx == -1) begin
                free_idx = i;
            end
        end
    end

    // -------------------------
    // Sequential logic
    // -------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dma_issue_valid  <= 0;
            tile_ready_valid <= 0;

            for (i = 0; i < PT_ENTRIES; i = i + 1) begin
                pt_valid[i]  <= 0;
                pt_issued[i] <= 0;
            end
        end else begin
            dma_issue_valid  <= 0;
            tile_ready_valid <= 0;

            // -------------------------
            // New request
            // -------------------------
            if (req_valid) begin
                if (hit_idx != -1) begin
                    // Already tracked, just associate GID
                    pt_gid[hit_idx] <= req_gid;
                end
                else if (free_idx != -1) begin
                    pt_valid[free_idx]  <= 1'b1;
                    pt_issued[free_idx] <= 1'b0;
                    pt_base[free_idx]   <= req_base;
                    pt_len[free_idx]    <= req_len;
                    pt_gid[free_idx]    <= req_gid;
                end
            end

            // -------------------------
            // Issue DMA
            // -------------------------
            for (i = 0; i < PT_ENTRIES; i = i + 1) begin
                if (pt_valid[i] && !pt_issued[i] && dma_issue_ready) begin
                    dma_issue_valid <= 1'b1;
                    dma_issue_base  <= pt_base[i];
                    dma_issue_len   <= pt_len[i];
                    pt_issued[i]    <= 1'b1;
                    pt_tag[i]       <= i[TAG_WIDTH-1:0];
                    disable issue_loop;
                end
            end
            issue_loop: ;

            // -------------------------
            // DMA completion
            // -------------------------
            if (dma_done_valid) begin
                for (i = 0; i < PT_ENTRIES; i = i + 1) begin
                    if (pt_valid[i] && pt_issued[i] &&
                        pt_tag[i] == dma_done_tag) begin

                        tile_ready_valid <= 1'b1;
                        tile_ready_gid   <= pt_gid[i];

                        pt_valid[i]  <= 1'b0;
                        pt_issued[i] <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
