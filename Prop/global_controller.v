// global_controller.v
// Very coarse scheduler that can be expanded to the paper's global controller
module global_controller #(
    parameter GROUP_ROWS = 4
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    output reg sftm_busy,
    output reg dpm_busy,
    input wire fifo_full,
    output reg bypass_mode,
    output reg busy
);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sftm_busy <= 0;
        dpm_busy <= 0;
        bypass_mode <= 0;
        busy <= 0;
    end else begin
        if (start) begin
            busy <= 1;
            sftm_busy <= 1;
            dpm_busy <= 1;
        end
        if (fifo_full) begin
            // optionally enable bypass
            bypass_mode <= 1;
        end
    end
end

endmodule
