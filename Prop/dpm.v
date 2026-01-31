// dpm.v
// DPM: Deformable Processing Module - performs deformable convolution
// Consumes FIFO data (transformed features) and reference pixels to compute output
// Implements a paper-structured (Fig.6/Fig.7-style) datapath: RA ping-pong buffers,
// address converter, coefficient generator, shift quantizer, and a shift-add SBCU.
//
// Offsets (fifo stream) expectation:
// - offset_x/offset_y are signed fixed-point with FRAC_BITS fractional bits.
// - Integer part P[i] = offset >>> FRAC_BITS drives the address converter.
// - Fractional part Q[i] = offset[FRAC_BITS-1:0] drives coeff_gen + shift quantizer.

`timescale 1ns/1ps
module dpm #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4,
    parameter KERNEL_SIZE = 3,
    parameter REF_BUF_SIZE = 16,  // Reference frame buffer size
    parameter FRAC_BITS = 8,
    parameter SB_SHIFT_W = 6
)(
    input wire clk,
    input wire rst_n,
    input wire start,
    
    // Input from FIFO (transformed features and offsets)
    input wire [DATA_W-1:0] fifo_data,
    input wire fifo_data_valid,
    output reg fifo_pop,
    
    // Reference frame data from prefetcher
    input wire [DATA_W-1:0] ref_data,
    input wire ref_data_valid,
    
    // Control
    input wire bypass_mode,
    
    // Output (deformable convolution result)
    output reg [DATA_W-1:0] dpm_out,
    output reg dpm_out_valid
);

// States
typedef enum reg [2:0] {
    IDLE = 0, 
    READ_FEATURES = 1, 
    READ_OFFSETS = 2,
    READ_REF = 3,
    COMPUTE_DEFORM = 4,
    OUTPUT = 5
} state_t;

state_t state;
reg [4:0] cnt;
reg [3:0] pixel_cnt;

// Internal buffers
reg signed [DATA_W-1:0] feature_buffer [0:GROUP_ROWS-1][0:GROUP_ROWS-1];
reg signed [DATA_W-1:0] offset_x [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];
reg signed [DATA_W-1:0] offset_y [0:KERNEL_SIZE-1][0:KERNEL_SIZE-1];

// Deformable convolution computation signals
reg signed [ACC_W-1:0] accumulator;
reg [3:0] kernel_i, kernel_j;
reg [4:0] compute_cnt;

// ===== Paper-structured sub-blocks =====
// RA ping-pong (tile buffer)
localparam integer REF_WORDS = (REF_BUF_SIZE*REF_BUF_SIZE);
localparam integer REF_ADDR_W = $clog2(REF_WORDS);

reg ra_start_fill;
reg ra_wr_en;
reg [REF_ADDR_W-1:0] ra_wr_addr;
reg [DATA_W-1:0] ra_wr_data;

wire ra_rd_bank_sel;
wire [DATA_W-1:0] ra_v00_u, ra_v01_u, ra_v10_u, ra_v11_u;

ra_pingpong #(
    .DATA_W(DATA_W),
    .W(REF_BUF_SIZE),
    .H(REF_BUF_SIZE)
) u_ra (
    .clk(clk),
    .rst_n(rst_n),
    .start_fill(ra_start_fill),
    .wr_en(ra_wr_en),
    .wr_addr(ra_wr_addr),
    .wr_data(ra_wr_data),
    .rd_bank_sel(ra_rd_bank_sel),
    .rd_addr0(ra_addr00_w),
    .rd_addr1(ra_addr01_w),
    .rd_addr2(ra_addr10_w),
    .rd_addr3(ra_addr11_w),
    .rd_data0(ra_v00_u),
    .rd_data1(ra_v01_u),
    .rd_data2(ra_v10_u),
    .rd_data3(ra_v11_u)
);

wire signed [DATA_W-1:0] ra_v00 = ra_v00_u;
wire signed [DATA_W-1:0] ra_v01 = ra_v01_u;
wire signed [DATA_W-1:0] ra_v10 = ra_v10_u;
wire signed [DATA_W-1:0] ra_v11 = ra_v11_u;

// Address conversion and coefficient path for current kernel tap
wire [3:0] base_x0_w = {2'b00, pixel_cnt[1:0]} + kernel_j[3:0];
wire [3:0] base_y0_w = {2'b00, pixel_cnt[3:2]} + kernel_i[3:0];
wire signed [DATA_W-1:0] off_x_cur = offset_x[kernel_i][kernel_j];
wire signed [DATA_W-1:0] off_y_cur = offset_y[kernel_i][kernel_j];

wire [3:0] base_x_clipped, base_y_clipped;
wire [FRAC_BITS-1:0] frac_x, frac_y;

addr_conv_paper #(
    .DATA_W(DATA_W),
    .FRAC_BITS(FRAC_BITS),
    .IDX_W(4),
    .MAX_X(REF_BUF_SIZE),
    .MAX_Y(REF_BUF_SIZE)
) u_addr (
    .off_x(off_x_cur),
    .off_y(off_y_cur),
    .base_x0(base_x0_w),
    .base_y0(base_y0_w),
    .base_x(base_x_clipped),
    .base_y(base_y_clipped),
    .frac_x(frac_x),
    .frac_y(frac_y)
);

// Neighbor addresses in the RA tile buffer
wire [REF_ADDR_W-1:0] ra_addr00_w = (base_y_clipped * REF_BUF_SIZE) + base_x_clipped;
wire [REF_ADDR_W-1:0] ra_addr01_w = (base_y_clipped * REF_BUF_SIZE) + (base_x_clipped + 1'b1);
wire [REF_ADDR_W-1:0] ra_addr10_w = ((base_y_clipped + 1'b1) * REF_BUF_SIZE) + base_x_clipped;
wire [REF_ADDR_W-1:0] ra_addr11_w = ((base_y_clipped + 1'b1) * REF_BUF_SIZE) + (base_x_clipped + 1'b1);

reg sb_valid_in;
wire sb_valid_out;
wire signed [DATA_W-1:0] sb_out;

// Bit-exact SBilinear per Algorithm 1 (N=2, M=15)
sbilinear_algo1 #(
    .DATA_W(DATA_W),
    .FRAC_BITS(FRAC_BITS),
    .ACC_W(ACC_W),
    .N(2),
    .M(15)
) u_sb (
    .clk(clk),
    .rst_n(rst_n),
    .valid_in(sb_valid_in),
    .v00(ra_v00),
    .v01(ra_v01),
    .v10(ra_v10),
    .v11(ra_v11),
    .frac_x(frac_x),
    .frac_y(frac_y),
    .out(sb_out),
    .valid_out(sb_valid_out)
);

reg sb_waiting;
reg signed [DATA_W-1:0] feature_mul_reg;

// Main FSM
integer i, j;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= IDLE;
        fifo_pop <= 0;
        cnt <= 0;
        pixel_cnt <= 0;
        dpm_out <= 0;
        dpm_out_valid <= 0;
        accumulator <= 0;
        kernel_i <= 0;
        kernel_j <= 0;
        compute_cnt <= 0;

        ra_start_fill <= 0;
        ra_wr_en <= 0;
        ra_wr_addr <= 0;
        ra_wr_data <= 0;
        sb_valid_in <= 0;
        sb_waiting <= 0;
        feature_mul_reg <= 0;
        
        // Clear buffers
        for (i = 0; i < GROUP_ROWS; i = i + 1)
            for (j = 0; j < GROUP_ROWS; j = j + 1)
                feature_buffer[i][j] <= 0;
                
        for (i = 0; i < KERNEL_SIZE; i = i + 1)
            for (j = 0; j < KERNEL_SIZE; j = j + 1) begin
                offset_x[i][j] <= 0;
                offset_y[i][j] <= 0;
            end
            
    end else begin
        dpm_out_valid <= 1'b0;
        sb_valid_in <= 1'b0;
        ra_wr_en <= 1'b0;
        ra_start_fill <= 1'b0;
        
        case (state)
            IDLE: begin
                fifo_pop <= 0;
                cnt <= 0;
                if (start) begin
                    state <= READ_FEATURES;
                    cnt <= 0;
                end
            end
            
            READ_FEATURES: begin
                // Read transformed features from FIFO
                if (fifo_data_valid) begin
                    fifo_pop <= 1'b1;
                    feature_buffer[cnt[3:2]][cnt[1:0]] <= fifo_data;
                    cnt <= cnt + 1;
                    if (cnt == (GROUP_ROWS * GROUP_ROWS - 1)) begin
                        state <= READ_OFFSETS;
                        cnt <= 0;
                        fifo_pop <= 1'b0;
                    end
                end else begin
                    fifo_pop <= 1'b0;
                end
            end
            
            READ_OFFSETS: begin
                // Read deformable offsets from FIFO
                if (fifo_data_valid) begin
                    fifo_pop <= 1'b1;
                    if (cnt < KERNEL_SIZE * KERNEL_SIZE) begin
                        offset_x[cnt / KERNEL_SIZE][cnt % KERNEL_SIZE] <= fifo_data;
                    end else begin
                        offset_y[(cnt - KERNEL_SIZE*KERNEL_SIZE) / KERNEL_SIZE]
                                [(cnt - KERNEL_SIZE*KERNEL_SIZE) % KERNEL_SIZE] <= fifo_data;
                    end
                    cnt <= cnt + 1;
                    if (cnt == (2 * KERNEL_SIZE * KERNEL_SIZE - 1)) begin
                        state <= READ_REF;
                        cnt <= 0;
                        fifo_pop <= 1'b0;
                    end
                end else begin
                    fifo_pop <= 1'b0;
                end
            end
            
            READ_REF: begin
                // Read reference pixels (prefetched by split_prefetcher) into RA ping-pong
                // Start a new fill on entry to this state.
                if (cnt == 0) begin
                    ra_start_fill <= 1'b1;
                    ra_wr_addr <= 0;
                end

                if (ref_data_valid) begin
                    ra_wr_en <= 1'b1;
                    ra_wr_data <= ref_data;
                    ra_wr_addr <= ra_wr_addr + 1'b1;
                    cnt <= cnt + 1;

                    if (cnt == (REF_WORDS - 1)) begin
                        state <= COMPUTE_DEFORM;
                        cnt <= 0;
                        accumulator <= 0;
                        kernel_i <= 0;
                        kernel_j <= 0;
                        compute_cnt <= 0;
                        sb_waiting <= 1'b0;
                    end
                end
            end
            
            COMPUTE_DEFORM: begin
                // Sequential kernel-tap scheduling, 1-cycle SBCU latency.
                if (compute_cnt < (KERNEL_SIZE * KERNEL_SIZE)) begin
                    if (!sb_waiting) begin
                        // Launch SBCU for current tap
                        feature_mul_reg <= feature_buffer[kernel_i][kernel_j];
                        sb_valid_in <= 1'b1;
                        sb_waiting <= 1'b1;
                    end else if (sb_valid_out) begin
                        // Consume SBCU output and accumulate
                        accumulator <= accumulator + ($signed(sb_out) * $signed(feature_mul_reg));

                        // Advance kernel tap
                        if (kernel_j == KERNEL_SIZE-1) begin
                            kernel_j <= 0;
                            if (kernel_i == KERNEL_SIZE-1) begin
                                kernel_i <= 0;
                            end else begin
                                kernel_i <= kernel_i + 1;
                            end
                        end else begin
                            kernel_j <= kernel_j + 1;
                        end

                        compute_cnt <= compute_cnt + 1;
                        sb_waiting <= 1'b0;

                        if (compute_cnt == (KERNEL_SIZE * KERNEL_SIZE - 1)) begin
                            state <= OUTPUT;
                        end
                    end
                end
            end
            
            OUTPUT: begin
                // Output result
                dpm_out <= accumulator[DATA_W-1:0];
                dpm_out_valid <= 1'b1;
                
                pixel_cnt <= pixel_cnt + 1;
                if (pixel_cnt == GROUP_ROWS * GROUP_ROWS - 1) begin
                    state <= IDLE;
                    pixel_cnt <= 0;
                end else begin
                    state <= COMPUTE_DEFORM;
                    accumulator <= 0;
                    kernel_i <= 0;
                    kernel_j <= 0;
                    compute_cnt <= 0;
                    sb_waiting <= 1'b0;
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
