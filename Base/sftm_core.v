//====================================================
// SFTM Core (Minimal, Cycle-Accurate)
//====================================================

module sftm_core #(
    parameter integer POF = 4,
    parameter integer PIF = 12,
    parameter integer SCU_MULTIPLIERS = 18,
    parameter integer PRETU_LATENCY = 4,
    parameter integer POSTTU_LATENCY = 4,
    parameter integer SCU_PIPELINE_LATENCY = 2,
    parameter integer MULT_WIDTH = 32,
    parameter integer FIFO_DEPTH = 8
)(
    input  wire clk,
    input  wire rst_n,

    // Job interface
    input  wire job_valid,
    input  wire [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat,
    input  wire start,

    output reg  busy,
    output reg  job_done
);

    // ------------------------------------------------
    // Job FIFO (only stores assigned_mults_flat)
    // ------------------------------------------------
    wire fifo_full, fifo_empty;
    wire [POF*PIF*MULT_WIDTH-1:0] fifo_rd_data;

    job_fifo #(
        .DEPTH(FIFO_DEPTH),
        .DATA_WIDTH(POF*PIF*MULT_WIDTH),
        .ADDR_WIDTH($clog2(FIFO_DEPTH))
    ) u_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(job_valid && !fifo_full),
        .wr_data(assigned_mults_flat),
        .full(fifo_full),
        .rd_en(start && !fifo_empty && !busy),
        .rd_data(fifo_rd_data),
        .empty(fifo_empty)
    );

    // ------------------------------------------------
    // PreTU / PostTU
    // ------------------------------------------------
    wire pre_done, pre_busy;
    wire post_done, post_busy;

    fixed_latency_pipe #(.LATENCY(PRETU_LATENCY)) u_pretu (
        .clk(clk), .rst_n(rst_n),
        .start(start && !fifo_empty && !busy),
        .busy(pre_busy),
        .done(pre_done)
    );

    fixed_latency_pipe #(.LATENCY(POSTTU_LATENCY)) u_posttu (
        .clk(clk), .rst_n(rst_n),
        .start(pre_done && scu_all_done),
        .busy(post_busy),
        .done(post_done)
    );

    // ------------------------------------------------
    // SCU Grid
    // ------------------------------------------------
    wire [POF*PIF-1:0] scu_done;
    wire [POF*PIF-1:0] scu_busy;

    genvar r, c;
    generate
        for (r = 0; r < POF; r = r + 1) begin : ROW
            for (c = 0; c < PIF; c = c + 1) begin : COL
                localparam integer IDX = r*PIF + c;

                scu #(
                    .SCU_MULTIPLIERS(SCU_MULTIPLIERS),
                    .MULT_WIDTH(MULT_WIDTH)
                ) u_scu (
                    .clk(clk),
                    .rst_n(rst_n),
                    .start(pre_done),
                    .assigned_mults(
                        fifo_rd_data[IDX*MULT_WIDTH +: MULT_WIDTH]
                    ),
                    .busy(scu_busy[IDX]),
                    .done(scu_done[IDX]),
                    .cycles_used()
                );
            end
        end
    endgenerate

    // ------------------------------------------------
    // SCU completion detect
    // ------------------------------------------------
    reg scu_all_done;
    integer i;

    always @(*) begin
        scu_all_done = 1'b1;
        for (i = 0; i < POF*PIF; i = i + 1)
            if (!scu_done[i])
                scu_all_done = 1'b0;
    end

    // ------------------------------------------------
    // Control FSM
    // ------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy     <= 1'b0;
            job_done <= 1'b0;
        end else begin
            job_done <= 1'b0;

            if (start && !fifo_empty && !busy)
                busy <= 1'b1;

            if (post_done) begin
                busy     <= 1'b0;
                job_done <= 1'b1;
            end
        end
    end

endmodule
