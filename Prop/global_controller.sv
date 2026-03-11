// global_controller.v
// Global Controller with proper scheduling and resource management
// Coordinates SFTM, DPM, FIFO, and memory access based on system state
// Implements adaptive bypass mode and credit-based flow control

module global_controller #(
    parameter GROUP_ROWS = 4,
    parameter MAX_CREDITS = 2,
    parameter FIFO_DEPTH = 8,
    parameter GROUP_WORDS = 32
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    
    // Status inputs from modules
    input wire sftm_group_done,
    input wire dpm_processing,
    input wire fifo_full,
    input wire fifo_empty,
    input wire credit_available,
    input wire prefetch_busy,
    
    // FIFO status
    input wire [7:0] fifo_count,

    // Consumer drain markers (for group-atomic draining)
    input wire drain_word,
    input wire drain_last,
    
    // Control outputs
    output reg sftm_enable,
    output reg dpm_enable,
    output reg bypass_mode,
    output reg prefetch_enable,
    
    // Status outputs
    output reg busy,
    output reg error,
    output reg [1:0] system_state
);

// System states
localparam [1:0] 
    STATE_IDLE = 2'b00,
    STATE_RUNNING = 2'b01,
    STATE_STALLED = 2'b10,
    STATE_ERROR = 2'b11;

// Internal state machine
typedef enum reg [2:0] {
    IDLE = 0,
    INIT = 1,
    NORMAL_OP = 2,
    BYPASS_OP = 3,
    WAIT_DRAIN = 4,
    DONE = 5
} ctrl_state_t;

ctrl_state_t ctrl_state;

// Group-atomic production: once we start a group, keep SFTM enabled until done.
reg producing_group;

// Ensure drain/backpressure is group-atomic: once we start draining a group,
// keep consumer enabled until the end-of-group marker is observed.
reg draining_group;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        draining_group <= 1'b0;
    end else if (ctrl_state == IDLE) begin
        draining_group <= 1'b0;
    end else if (drain_word) begin
        if (drain_last)
            draining_group <= 1'b0;
        else
            draining_group <= 1'b1;
    end else if (fifo_empty) begin
        // Fail-safe: if FIFO is empty, there cannot be a partially-drained group.
        draining_group <= 1'b0;
    end
end

// Performance monitoring
reg [15:0] cycle_count;
reg [7:0] groups_processed;
reg [7:0] stall_count;
reg [7:0] bypass_count;

// Threshold parameters
localparam FIFO_HIGH_THRESHOLD = (FIFO_DEPTH * 3) / 4;  // 75% full
localparam FIFO_LOW_THRESHOLD = FIFO_DEPTH / 4;         // 25% full
localparam STALL_THRESHOLD = 10;                         // Max stalls before bypass

// Control logic
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ctrl_state <= IDLE;
        sftm_enable <= 0;
        dpm_enable <= 0;
        bypass_mode <= 0;
        prefetch_enable <= 0;
        busy <= 0;
        error <= 0;
        system_state <= STATE_IDLE;
        cycle_count <= 0;
        groups_processed <= 0;
        stall_count <= 0;
        bypass_count <= 0;
        producing_group <= 1'b0;
    end else begin
        cycle_count <= cycle_count + 1;
        // Error is a transient flag (not sticky) so a momentary FIFO-full event
        // doesn't permanently poison later runs.
        error <= 1'b0;
        
        case (ctrl_state)
            IDLE: begin
                busy <= 0;
                sftm_enable <= 0;
                dpm_enable <= 0;
                bypass_mode <= 0;
                prefetch_enable <= 0;
                system_state <= STATE_IDLE;
                producing_group <= 1'b0;
                
                if (start) begin
                    ctrl_state <= INIT;
                    busy <= 1;
                    cycle_count <= 0;
                    groups_processed <= 0;
                    stall_count <= 0;
                    bypass_count <= 0;
                end
            end
            
            INIT: begin
                // Initialize modules
                sftm_enable <= 1'b1;
                dpm_enable <= 1'b1;
                prefetch_enable <= 1'b1;
                system_state <= STATE_RUNNING;
                ctrl_state <= NORMAL_OP;
                producing_group <= 1'b0;
            end
            
            NORMAL_OP: begin
                system_state <= STATE_RUNNING;
                
                // SFTM control (group-atomic):
                // - If we are in the middle of producing a group, keep SFTM enabled until group_done.
                // - If idle between groups, start a new group only if there's enough FIFO space.
                if (sftm_group_done) begin
                    producing_group <= 1'b0;
                end

                if (producing_group) begin
                    sftm_enable <= 1'b1;
                    stall_count <= 0;
                end else begin
                    // Space for an entire group: keep at least GROUP_WORDS free entries.
                    if (!fifo_full && (fifo_count <= (FIFO_DEPTH - GROUP_WORDS))) begin
                        sftm_enable <= 1'b1;
                        producing_group <= 1'b1;
                        stall_count <= 0;
                    end else begin
                        sftm_enable <= 1'b0;
                        stall_count <= stall_count + 1;

                        // Enter bypass if stalled too long
                        if (stall_count >= STALL_THRESHOLD) begin
                            ctrl_state <= BYPASS_OP;
                            bypass_mode <= 1'b1;
                            bypass_count <= bypass_count + 1;
                        end
                    end
                end
                
                // DPM control (diagram-faithful): enable only if at least one complete group exists.
                // Keep enabled while draining_group is set.
                if (credit_available || draining_group) begin
                    dpm_enable <= 1'b1;
                end else begin
                    dpm_enable <= 1'b0;
                end
                
                // Prefetcher control: enable when groups are produced
                if (sftm_group_done && !prefetch_busy) begin
                    prefetch_enable <= 1'b1;
                    groups_processed <= groups_processed + 1;
                end else begin
                    prefetch_enable <= 1'b0;
                end
                
                // End-of-run: once start drops, stop producing and drain.
                // (Don't wait for FIFO empty first; that can deadlock if we
                // need consumer activity to observe end-of-group markers.)
                if (!start) begin
                    ctrl_state <= WAIT_DRAIN;
                end
                
                // Adaptive FIFO management
                if (fifo_count >= FIFO_HIGH_THRESHOLD) begin
                    // FIFO filling up - slow down SFTM
                    sftm_enable <= 1'b0;
                    system_state <= STATE_STALLED;
                end else if (fifo_count <= FIFO_LOW_THRESHOLD && !fifo_empty) begin
                    // FIFO draining - speed up SFTM
                    // No-op: group-atomic start is handled above.
                end
            end
            
            BYPASS_OP: begin
                system_state <= STATE_RUNNING;
                bypass_mode <= 1'b1;
                
                // In bypass mode, skip transform pipeline
                sftm_enable <= 1'b1;  // Still produce data but through bypass
                dpm_enable <= 1'b1;
                producing_group <= 1'b0;
                
                // Exit bypass when FIFO pressure relieved
                if (fifo_count <= FIFO_LOW_THRESHOLD) begin
                    bypass_mode <= 1'b0;
                    ctrl_state <= NORMAL_OP;
                    stall_count <= 0;
                end

                // Also allow clean termination from bypass mode
                if (!start) begin
                    ctrl_state <= WAIT_DRAIN;
                end
            end
            
            WAIT_DRAIN: begin
                // Wait for pipeline to drain
                sftm_enable <= 1'b0;
                prefetch_enable <= 1'b0;
                system_state <= STATE_RUNNING;
                producing_group <= 1'b0;

                // Only allow disabling the consumer between groups
                if (!dpm_processing && !draining_group) begin
                    dpm_enable <= 1'b0;
                end else begin
                    dpm_enable <= 1'b1;
                end

                if (fifo_empty && !dpm_processing && !draining_group) begin
                    ctrl_state <= DONE;
                end
            end
            
            DONE: begin
                busy <= 0;
                sftm_enable <= 0;
                dpm_enable <= 0;
                bypass_mode <= 0;
                prefetch_enable <= 0;
                system_state <= STATE_IDLE;
                ctrl_state <= IDLE;
                producing_group <= 1'b0;
            end
            
            default: ctrl_state <= IDLE;
        endcase
        
        // Error detection
        if (fifo_full && sftm_enable) begin
            error <= 1'b1;
            system_state <= STATE_ERROR;
        end
    end
end

// Performance counters (can be read for debugging)
reg [31:0] total_cycles;
reg [15:0] bypass_cycles;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        total_cycles <= 0;
        bypass_cycles <= 0;
    end else begin
        if (busy) begin
            total_cycles <= total_cycles + 1;
        end
        if (bypass_mode) begin
            bypass_cycles <= bypass_cycles + 1;
        end
    end
end

endmodule
