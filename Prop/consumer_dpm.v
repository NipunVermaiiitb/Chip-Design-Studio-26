//====================================================
// Consumer DPM (Timing Model)
//====================================================
// Consumes TileGroups at a programmable rate
//====================================================

module consumer_dpm #(
    parameter integer FRAME_COLS = 1920,
    parameter integer BASE_PERIOD = 140,
    parameter integer JITTER = 4,
    parameter integer WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    input  wire start,

    // Configuration
    input  wire [WIDTH-1:0] tile_columns,

    // Control
    input  wire consume_start,   // asserted when FIFO front is ready

    // Status
    output reg  ready_to_consume,
    output reg  [31:0] consumed_count
);

    // -------------------------
    // Internal state
    // -------------------------
    reg [31:0] cycle;
    reg [31:0] next_consume;

    reg [WIDTH-1:0] num_col_tiles;
    reg [WIDTH-1:0] period_per_tile;

    // Simple LFSR for jitter
    reg [7:0] lfsr;
    wire signed [7:0] jitter_val;

    assign jitter_val = (JITTER == 0) ? 0 :
                        (lfsr[3:0] - lfsr[7:4]);

    // ceiling division
    function [WIDTH-1:0] ceil_div;
        input [WIDTH-1:0] a, b;
        begin
            ceil_div = (a + b - 1) / b;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle           <= 0;
            next_consume    <= 1;
            consumed_count  <= 0;
            ready_to_consume<= 1'b0;
            lfsr            <= 8'h3C;
        end else begin
            cycle <= cycle + 1'b1;

            // LFSR advance
            lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5]};

            if (start && consumed_count == 0) begin
                num_col_tiles   <= ceil_div(FRAME_COLS, tile_columns);
                period_per_tile <= (BASE_PERIOD / ceil_div(FRAME_COLS, tile_columns));
                next_consume    <= 1;
            end

            // Ready condition
            if (cycle >= next_consume)
                ready_to_consume <= 1'b1;
            else
                ready_to_consume <= 1'b0;

            // Start consumption
            if (consume_start && ready_to_consume) begin
                consumed_count <= consumed_count + 1'b1;
                next_consume <= cycle +
                                ((period_per_tile > 0) ? period_per_tile : 1) +
                                jitter_val;
            end
        end
    end

endmodule
