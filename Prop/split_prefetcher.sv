// split_prefetcher.v
// Issues DRAM read requests for reference frame regions corresponding to groups
// Implements proper address generation based on frame dimensions and group indices
// Supports configurable frame sizes and tile-based access patterns

`timescale 1ns/1ps
module split_prefetcher #(
    parameter ADDR_WIDTH = 32,
    parameter FRAME_WIDTH = 1920,   // Frame width in pixels
    parameter FRAME_HEIGHT = 1080,  // Frame height in pixels
    parameter TILE_SIZE = 16,       // Tile size for prefetching
    parameter GROUP_ROWS = 4        // Group size
)(
    input  wire clk,
    input  wire rst_n,
    
    // Configuration
    input  wire [15:0] frame_width,
    input  wire [15:0] frame_height,
    input  wire [ADDR_WIDTH-1:0] ref_frame_base_addr,
    
    // Control
    input  wire group_done,         // Trigger from SFTM
    input  wire [15:0] group_x,     // Group position X
    input  wire [15:0] group_y,     // Group position Y
    
    // DRAM interface
    output reg  issue_req,
    output reg  [ADDR_WIDTH-1:0] addr,
    output reg  [15:0] len,         // Length in words
    input  wire dram_ack,
    input  wire dram_data_valid,
    
    // Status
    output wire busy
);

// States
typedef enum reg [2:0] {
    IDLE = 0,
    CALC_ADDR = 1,
    ISSUE_REQ = 2,
    WAIT_ACK = 3,
    WAIT_STREAM = 4
} state_t;

state_t state;

// Internal registers
reg pending;
reg [15:0] current_group_x;
reg [15:0] current_group_y;
reg [15:0] fetch_width;
reg [15:0] fetch_height;
reg [ADDR_WIDTH-1:0] calculated_addr;
reg [15:0] calculated_len;
reg [15:0] active_len;
reg [15:0] beat_cnt;

// One-entry queue so we don't drop group_done while a stream is in flight.
reg next_valid;
reg [15:0] next_group_x_reg;
reg [15:0] next_group_y_reg;

assign busy = (state != IDLE);

// Address calculation function
// Calculates byte address for reference region based on group position
function [ADDR_WIDTH-1:0] calc_ref_addr;
    input [ADDR_WIDTH-1:0] base_addr;
    input [15:0] x_pos;
    input [15:0] y_pos;
    input [15:0] width;
    input [15:0] tile_size;
    reg [ADDR_WIDTH-1:0] offset;
    reg [15:0] pixel_x, pixel_y;
begin
    // Convert group position to pixel position
    pixel_x = x_pos * tile_size;
    pixel_y = y_pos * tile_size;
    
    // Calculate offset: (y * frame_width + x) * bytes_per_pixel
    // Assuming 2 bytes per pixel (16-bit data)
    offset = (pixel_y * width + pixel_x) * 2;
    
    calc_ref_addr = base_addr + offset;
end
endfunction

// Length calculation: fetch tile_size x tile_size region
function [15:0] calc_fetch_len;
    input [15:0] tile_size;
begin
    // Return number of words to fetch (tile_size * tile_size)
    calc_fetch_len = tile_size * tile_size;
end
endfunction

// Main FSM
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        issue_req <= 0;
        addr <= 0;
        len <= 0;
        pending <= 0;
        current_group_x <= 0;
        current_group_y <= 0;
        fetch_width <= TILE_SIZE;
        fetch_height <= TILE_SIZE;
        calculated_addr <= 0;
        calculated_len <= 0;
        active_len <= 0;
        beat_cnt <= 0;
        next_valid <= 1'b0;
        next_group_x_reg <= 0;
        next_group_y_reg <= 0;
    end else begin
        // Queue the next group trigger if we're busy and none is queued yet.
        if ((state != IDLE) && group_done && !next_valid) begin
            next_group_x_reg <= group_x;
            next_group_y_reg <= group_y;
            next_valid <= 1'b1;
        end

        case (state)
            IDLE: begin
                issue_req <= 0;
                beat_cnt <= 0;
                if (next_valid) begin
                    // Drain queued trigger first.
                    current_group_x <= next_group_x_reg;
                    current_group_y <= next_group_y_reg;
                    next_valid <= 1'b0;
                    state <= CALC_ADDR;
                end else if (group_done && !pending) begin
                    // Capture group position
                    current_group_x <= group_x;
                    current_group_y <= group_y;
                    state <= CALC_ADDR;
                end
            end
            
            CALC_ADDR: begin
                // Calculate address and length based on group position
                calculated_addr <= calc_ref_addr(
                    ref_frame_base_addr,
                    current_group_x,
                    current_group_y,
                    frame_width,
                    TILE_SIZE
                );
                
                calculated_len <= calc_fetch_len(TILE_SIZE);
                
                // Bounds checking
                if ((current_group_x * TILE_SIZE + TILE_SIZE) > frame_width ||
                    (current_group_y * TILE_SIZE + TILE_SIZE) > frame_height) begin
                    // Out of bounds - adjust fetch size
                    if ((current_group_x * TILE_SIZE + TILE_SIZE) > frame_width) begin
                        fetch_width <= frame_width - (current_group_x * TILE_SIZE);
                    end else begin
                        fetch_width <= TILE_SIZE;
                    end
                    
                    if ((current_group_y * TILE_SIZE + TILE_SIZE) > frame_height) begin
                        fetch_height <= frame_height - (current_group_y * TILE_SIZE);
                    end else begin
                        fetch_height <= TILE_SIZE;
                    end
                    
                    calculated_len <= fetch_width * fetch_height;
                end
                
                state <= ISSUE_REQ;
            end
            
            ISSUE_REQ: begin
                // Issue the request
                addr <= calculated_addr;
                len <= calculated_len;
                issue_req <= 1'b1;
                pending <= 1'b1;
                active_len <= calculated_len;
                beat_cnt <= 0;
                state <= WAIT_ACK;
            end
            
            WAIT_ACK: begin
                if (dram_ack) begin
                    // Request acknowledged; now wait for the full stream (active_len beats)
                    issue_req <= 1'b0;
                    state <= WAIT_STREAM;
                end
            end

            WAIT_STREAM: begin
                // Count beats to ensure no overlapping bursts.
                if (dram_data_valid) begin
                    if (beat_cnt == (active_len - 1)) begin
                        pending <= 1'b0;
                        beat_cnt <= 0;
                        state <= IDLE;
                    end else begin
                        beat_cnt <= beat_cnt + 1'b1;
                    end
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
