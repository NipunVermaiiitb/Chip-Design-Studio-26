`timescale 1ns/1ps

module tb_banked_group_fifo;

    localparam BANKS = 2;
    localparam GROUP_SLOTS = 2;
    localparam DEPTH = BANKS * GROUP_SLOTS;
    localparam GID_WIDTH = 16;

    reg clk, rst_n;
    reg push_valid;
    reg pop_ready;
    reg [GID_WIDTH-1:0] push_gid;

    wire push_ready;
    wire pop_valid;
    wire [GID_WIDTH-1:0] pop_gid;
    wire peek_valid;
    wire [GID_WIDTH-1:0] peek_gid;
    wire overflow;
    wire [2:0] occupancy;

    integer i;
    integer error_count;

    banked_group_fifo #(
        .BANKS(BANKS),
        .GROUP_SLOTS(GROUP_SLOTS),
        .GID_WIDTH(GID_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .push_valid(push_valid),
        .push_gid(push_gid),
        .push_ready(push_ready),
        .push_bank(),
        .push_slot(),
        .peek_valid(peek_valid),
        .peek_gid(peek_gid),
        .pop_ready(pop_ready),
        .pop_valid(pop_valid),
        .pop_gid(pop_gid),
        .occupancy(occupancy),
        .overflow(overflow)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        push_valid = 0;
        pop_ready = 0;
        push_gid = 0;
        error_count = 0;

        #20 rst_n = 1;

        // Fill FIFO
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            push_valid = 1;
            push_gid = i + 1;
        end
        push_valid = 0;

        // Overflow attempt
        @(posedge clk);
        push_valid = 1;
        push_gid = 99;
        @(posedge clk);
        if (!overflow) begin
            $display("ERROR: overflow not detected");
            error_count = error_count + 1;
        end
        push_valid = 0;

        // Pop all and check order
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            pop_ready = 1;
            @(posedge clk);
            if (!pop_valid || pop_gid != i + 1) begin
                $display("ERROR: pop mismatch exp=%0d got=%0d", i+1, pop_gid);
                error_count = error_count + 1;
            end
        end
        pop_ready = 0;

        if (error_count == 0)
            $display("PASS: banked_group_fifo works as intended");
        else
            $display("FAIL: banked_group_fifo has %0d errors", error_count);

        $finish;
    end

endmodule
