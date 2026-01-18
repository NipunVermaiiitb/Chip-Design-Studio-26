//====================================================
// Banked Group FIFO
//====================================================

module banked_group_fifo #(
    parameter integer BANKS = 4,
    parameter integer GROUP_SLOTS = 2,
    parameter integer GID_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    // Push interface
    input  wire push_valid,
    input  wire [GID_WIDTH-1:0] push_gid,
    output reg  push_ready,
    output reg  [$clog2(BANKS)-1:0] push_bank,
    output reg  [$clog2(GROUP_SLOTS)-1:0] push_slot,

    // Peek interface
    output reg  peek_valid,
    output reg  [GID_WIDTH-1:0] peek_gid,

    // Pop interface
    input  wire pop_ready,
    output reg  pop_valid,
    output reg  [GID_WIDTH-1:0] pop_gid,

    // Status
    output reg  [$clog2(BANKS*GROUP_SLOTS+1)-1:0] occupancy,
    output reg  overflow
);

    localparam integer DEPTH = BANKS * GROUP_SLOTS;
    localparam integer PTR_W = $clog2(DEPTH);

    // FIFO storage (gids only)
    reg [GID_WIDTH-1:0] fifo_mem [0:DEPTH-1];
    reg [PTR_W-1:0] rd_ptr, wr_ptr;

    // Bank slot state
    reg [GID_WIDTH-1:0] bank_slots [0:BANKS-1][0:GROUP_SLOTS-1];
    reg valid_bits [0:BANKS-1][0:GROUP_SLOTS-1];

    integer b, s;

    // combinational helpers
    always @(*) begin
        push_ready = (occupancy < DEPTH);
        peek_valid = (occupancy > 0);
        peek_gid   = fifo_mem[rd_ptr];
    end

    // main sequential logic
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            occupancy <= 0;
            rd_ptr    <= 0;
            wr_ptr    <= 0;
            overflow  <= 1'b0;
            pop_valid <= 1'b0;
            pop_gid   <= 0;
            push_bank <= 0;
            push_slot <= 0;

            for (b = 0; b < BANKS; b = b + 1)
                for (s = 0; s < GROUP_SLOTS; s = s + 1)
                    valid_bits[b][s] <= 1'b0;

        end else begin
            pop_valid <= 1'b0;
            overflow  <= 1'b0;

            // --------------------
            // PUSH
            // --------------------
            if (push_valid) begin
                if (push_ready) begin
                    fifo_mem[wr_ptr] <= push_gid;
                    wr_ptr <= wr_ptr + 1'b1;

                    // compute bank/slot from occupancy (pre-increment)
                    push_bank <= occupancy % BANKS;
                    push_slot <= occupancy / BANKS;

                    bank_slots[occupancy % BANKS][occupancy / BANKS] <= push_gid;
                    valid_bits[occupancy % BANKS][occupancy / BANKS] <= 1'b1;

                    occupancy <= occupancy + 1'b1;
                end else begin
                    overflow <= 1'b1;
                end
            end

            // --------------------
            // POP
            // --------------------
            if (pop_ready && occupancy > 0) begin
                pop_gid   <= fifo_mem[rd_ptr];
                pop_valid <= 1'b1;

                // clear bank slot
                for (b = 0; b < BANKS; b = b + 1)
                    for (s = 0; s < GROUP_SLOTS; s = s + 1)
                        if (valid_bits[b][s] && bank_slots[b][s] == fifo_mem[rd_ptr])
                            valid_bits[b][s] <= 1'b0;

                rd_ptr    <= rd_ptr + 1'b1;
                occupancy <= occupancy - 1'b1;
            end
        end
    end

endmodule
