// dpm.v
// DPM: Deformable Processing Module - performs deformable convolution
// Consumes FIFO data (transformed features) and reference pixels to compute output
// Implements bilinear interpolation for deformable sampling

`timescale 1ns/1ps
module dpm #(
    parameter DATA_W = 16,
    parameter ACC_W = 32,
    parameter N_CH = 36,
    parameter GROUP_ROWS = 4,
    parameter KERNEL_SIZE = 3,
    parameter REF_BUF_SIZE = 16  // Reference frame buffer size
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
reg signed [DATA_W-1:0] ref_buffer [0:REF_BUF_SIZE-1][0:REF_BUF_SIZE-1];

// Deformable convolution computation signals
reg signed [ACC_W-1:0] accumulator;
reg [3:0] kernel_i, kernel_j;
reg [4:0] compute_cnt;

// Bilinear interpolation function (simplified fixed-point)
function signed [DATA_W-1:0] bilinear_interp;
    input signed [DATA_W-1:0] p00, p01, p10, p11;  // Four neighboring pixels
    input signed [7:0] fx, fy;  // Fractional parts (0-255)
    reg signed [ACC_W-1:0] temp1, temp2, result;
begin
    // Interpolate in x direction
    temp1 = (p00 * (256 - fx) + p01 * fx) >>> 8;
    temp2 = (p10 * (256 - fx) + p11 * fx) >>> 8;
    // Interpolate in y direction
    result = (temp1 * (256 - fy) + temp2 * fy) >>> 8;
    bilinear_interp = result[DATA_W-1:0];
end
endfunction

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
                // Read reference pixels (prefetched by split_prefetcher)
                if (ref_data_valid) begin
                    ref_buffer[cnt[3:0] / REF_BUF_SIZE][cnt[3:0] % REF_BUF_SIZE] <= ref_data;
                    cnt <= cnt + 1;
                    if (cnt == (REF_BUF_SIZE * REF_BUF_SIZE - 1)) begin
                        state <= COMPUTE_DEFORM;
                        cnt <= 0;
                        accumulator <= 0;
                        kernel_i <= 0;
                        kernel_j <= 0;
                        compute_cnt <= 0;
                    end
                end
            end
            
            COMPUTE_DEFORM: begin
                // Perform deformable convolution computation
                // For each kernel position, apply offset and perform bilinear interpolation
                if (compute_cnt < KERNEL_SIZE * KERNEL_SIZE) begin
                    // Calculate sampling position with offset
                    reg signed [DATA_W-1:0] sample_x, sample_y;
                    reg [3:0] base_x, base_y;
                    reg [7:0] frac_x, frac_y;
                    reg signed [DATA_W-1:0] p00, p01, p10, p11;
                    reg signed [DATA_W-1:0] sampled_val;
                    
                    sample_x = pixel_cnt[1:0] + kernel_j + offset_x[kernel_i][kernel_j];
                    sample_y = pixel_cnt[3:2] + kernel_i + offset_y[kernel_i][kernel_j];
                    
                    // Extract integer and fractional parts
                    base_x = sample_x[DATA_W-1:8];
                    base_y = sample_y[DATA_W-1:8];
                    frac_x = sample_x[7:0];
                    frac_y = sample_y[7:0];
                    
                    // Bounds checking
                    if (base_x < REF_BUF_SIZE-1 && base_y < REF_BUF_SIZE-1) begin
                        // Fetch 4 neighboring pixels
                        p00 = ref_buffer[base_y][base_x];
                        p01 = ref_buffer[base_y][base_x+1];
                        p10 = ref_buffer[base_y+1][base_x];
                        p11 = ref_buffer[base_y+1][base_x+1];
                        
                        // Bilinear interpolation
                        sampled_val = bilinear_interp(p00, p01, p10, p11, frac_x, frac_y);
                        
                        // Accumulate with feature
                        accumulator <= accumulator + (sampled_val * feature_buffer[kernel_i][kernel_j]);
                    end
                    
                    // Move to next kernel position
                    if (kernel_j == KERNEL_SIZE-1) begin
                        kernel_j <= 0;
                        if (kernel_i == KERNEL_SIZE-1) begin
                            kernel_i <= 0;
                            state <= OUTPUT;
                        end else begin
                            kernel_i <= kernel_i + 1;
                        end
                    end else begin
                        kernel_j <= kernel_j + 1;
                    end
                    
                    compute_cnt <= compute_cnt + 1;
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
                end
            end
            
            default: state <= IDLE;
        endcase
    end
end

endmodule
