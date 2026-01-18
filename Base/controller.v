//====================================================
// Controller
// Multi-core scheduler for SFTM + DfConv
//====================================================

module controller #(
    parameter integer NUM_CORES = 2,
    parameter integer POF = 2,
    parameter integer PIF = 3,
    parameter integer MULT_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,

    // Tile input (from frame_tiler)
    input  wire tile_valid,
    input  wire is_dfconv,
    input  wire [15:0] rows,
    input  wire [15:0] cols,
    input  wire [15:0] in_ch,
    input  wire [15:0] out_ch,
    input  wire [POF*PIF*MULT_WIDTH-1:0] assigned_mults_flat,

    // Control
    input  wire start,

    output reg  busy,
    output reg  done
);

    // ------------------------------------------------
    // Per-core signals
    // ------------------------------------------------
    reg  [NUM_CORES-1:0] sftm_start;
    reg  [NUM_CORES-1:0] dfconv_start;

    wire [NUM_CORES-1:0] sftm_busy;
    wire [NUM_CORES-1:0] sftm_done;

    wire [NUM_CORES-1:0] dfconv_busy;
    wire [NUM_CORES-1:0] dfconv_done;

    integer core_ptr;
    integer active_jobs;
    integer i;

    // ------------------------------------------------
    // Core instantiation
    // ------------------------------------------------
    genvar c;
    generate
        for (c = 0; c < NUM_CORES; c = c + 1) begin : CORE

            sftm_core #(
                .POF(POF),
                .PIF(PIF),
                .MULT_WIDTH(MULT_WIDTH)
            ) u_sftm (
                .clk(clk),
                .rst_n(rst_n),
                .job_valid(tile_valid && !is_dfconv && core_ptr == c),
                .assigned_mults_flat(assigned_mults_flat),
                .start(sftm_start[c]),
                .busy(sftm_busy[c]),
                .job_done(sftm_done[c])
            );

            dfconv u_dfconv (
                .clk(clk),
                .rst_n(rst_n),
                .start(dfconv_start[c]),
                .rows(rows),
                .cols(cols),
                .in_ch(in_ch),
                .out_ch(out_ch),
                .busy(dfconv_busy[c]),
                .done(dfconv_done[c]),
                .cycles_used()
            );

        end
    endgenerate

    // ------------------------------------------------
    // Control FSM (simple, robust)
    // ------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_ptr    <= 0;
            active_jobs <= 0;
            busy        <= 1'b0;
            done        <= 1'b0;
            sftm_start  <= 0;
            dfconv_start<= 0;
        end else begin
            sftm_start   <= 0;
            dfconv_start <= 0;
            done         <= 1'b0;

            if (start)
                busy <= 1'b1;

            // Dispatch new tile
            if (tile_valid) begin
                if (is_dfconv) begin
                    dfconv_start[core_ptr] <= 1'b1;
                end else begin
                    sftm_start[core_ptr] <= 1'b1;
                end
                core_ptr <= (core_ptr + 1) % NUM_CORES;
                active_jobs <= active_jobs + 1;
            end

            // Completion tracking
            for (i = 0; i < NUM_CORES; i = i + 1) begin
                if (sftm_done[i] || dfconv_done[i])
                    active_jobs <= active_jobs - 1;
            end

            // All jobs done
            if (busy && active_jobs == 0 && !tile_valid) begin
                busy <= 1'b0;
                done <= 1'b1;
            end
        end
    end

endmodule
