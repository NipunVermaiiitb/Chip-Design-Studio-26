`timescale 1ns/1ps

module tb_job_fifo;

    localparam DATA_WIDTH = 128;
    localparam DEPTH = 8;
    localparam ADDR_WIDTH = 3;

    reg clk;
    reg rst_n;

    reg wr_en;
    reg rd_en;
    reg [DATA_WIDTH-1:0] wr_data;
    wire [DATA_WIDTH-1:0] rd_data;
    wire full;
    wire empty;

    integer i;
    integer error_count;

    job_fifo #(
        .DEPTH(DEPTH),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .wr_data(wr_data),
        .full(full),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .empty(empty)
    );

    always #5 clk = ~clk;

    initial begin
        clk = 0;
        rst_n = 0;
        wr_en = 0;
        rd_en = 0;
        wr_data = 0;
        error_count = 0;

        #20;
        rst_n = 1;

        // Write DEPTH entries
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            wr_en = 1;
            wr_data = i;
        end
        @(posedge clk);
        wr_en = 0;

        if (!full) begin
            $display("ERROR: FIFO should be full");
            error_count = error_count + 1;
        end

        // Read DEPTH entries and check order
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge clk);
            rd_en = 1;
            @(posedge clk);
            if (rd_data !== i) begin
                $display("ERROR: FIFO order mismatch. Expected=%0d Got=%0d", i, rd_data);
                error_count = error_count + 1;
            end
        end
        rd_en = 0;

        if (!empty) begin
            $display("ERROR: FIFO should be empty");
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("PASS: job_fifo works as intended");
        else
            $display("FAIL: job_fifo has %0d errors", error_count);

        $finish;
    end

endmodule
