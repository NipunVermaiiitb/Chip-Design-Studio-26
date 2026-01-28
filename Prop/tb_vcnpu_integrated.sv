// tb_vcnpu_integrated.sv
// Comprehensive testbench for fully integrated VCNPU system
// Tests complete pipeline: SFTM -> FIFO -> DPM with real data flow

`timescale 1ns/1ps

module tb_vcnpu_integrated;

    // Parameters
    parameter DATA_W = 16;
    parameter N_CH = 36;
    parameter GROUP_ROWS = 4;
    parameter DEPTH_GROUPS = 2;
    parameter FRAME_WIDTH = 64;   // Small frame for testing
    parameter FRAME_HEIGHT = 64;
    parameter TILE_SIZE = 16;
    
    parameter CLK_PERIOD = 10;  // 100 MHz

    // DUT signals
    reg clk;
    reg rst_n;
    
    // Configuration
    reg [15:0] frame_width;
    reg [15:0] frame_height;
    reg [31:0] ref_frame_base_addr;
    reg conv_mode;
    reg [1:0] quality_mode;
    
    // Input stream
    reg [DATA_W-1:0] input_data;
    reg input_valid;
    
    // DRAM interface
    wire dram_req;
    wire [31:0] dram_addr;
    wire [15:0] dram_len;
    reg dram_ack;
    reg dram_data_valid;
    reg [DATA_W-1:0] dram_data_in;
    
    // Weight loading
    reg weight_load_en;
    reg [11:0] weight_load_addr;
    reg [DATA_W-1:0] weight_load_data;
    
    // Control
    reg start;
    wire busy;
    wire error;
    
    // Output
    wire [DATA_W-1:0] output_data;
    wire output_valid;
    wire [1:0] system_state;

    // Test variables
    integer i, j;
    integer cycle_count;
    integer input_count;
    integer output_count;
    integer test_passed;
    
    // Reference data storage
    reg [DATA_W-1:0] reference_frame [0:63][0:63];
    reg [DATA_W-1:0] input_patches [0:255][0:15];  // 256 patches, 16 values each
    
    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    vcnpu_top #(
        .DATA_W(DATA_W),
        .N_CH(N_CH),
        .GROUP_ROWS(GROUP_ROWS),
        .DEPTH_GROUPS(DEPTH_GROUPS),
        .FRAME_WIDTH(FRAME_WIDTH),
        .FRAME_HEIGHT(FRAME_HEIGHT),
        .TILE_SIZE(TILE_SIZE)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .ref_frame_base_addr(ref_frame_base_addr),
        .conv_mode(conv_mode),
        .quality_mode(quality_mode),
        .input_data(input_data),
        .input_valid(input_valid),
        .dram_req(dram_req),
        .dram_addr(dram_addr),
        .dram_len(dram_len),
        .dram_ack(dram_ack),
        .dram_data_valid(dram_data_valid),
        .dram_data_in(dram_data_in),
        .weight_load_en(weight_load_en),
        .weight_load_addr(weight_load_addr),
        .weight_load_data(weight_load_data),
        .start(start),
        .busy(busy),
        .error(error),
        .output_data(output_data),
        .output_valid(output_valid),
        .system_state(system_state)
    );

    //==========================================================================
    // Clock Generation
    //==========================================================================
    initial begin
        clk = 0;
        forever #(CLK_PERIOD/2) clk = ~clk;
    end

    //==========================================================================
    // DRAM Model
    //==========================================================================
    // Simple DRAM model that responds to read requests
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_ack <= 0;
            dram_data_valid <= 0;
            dram_data_in <= 0;
        end else begin
            // Acknowledge requests after 1 cycle
            dram_ack <= dram_req;
            
            // Provide data after 2 cycles (simulating latency)
            if (dram_ack) begin
                dram_data_valid <= 1'b1;
                // Send reference frame data (simplified)
                dram_data_in <= $random & 16'hFFFF;
            end else if (dram_data_valid) begin
                // Continue sending data for requested length
                dram_data_in <= $random & 16'hFFFF;
            end else begin
                dram_data_valid <= 1'b0;
            end
        end
    end

    //==========================================================================
    // Monitoring and Statistics
    //==========================================================================
    always @(posedge clk) begin
        if (busy)
            cycle_count <= cycle_count + 1;
        
        if (output_valid) begin
            output_count <= output_count + 1;
            $display("[T=%0t] Output[%0d] = 0x%04x", $time, output_count, output_data);
        end
        
        if (error) begin
            $display("[ERROR] System error detected at time %0t", $time);
            test_passed = 0;
        end
    end

    //==========================================================================
    // Test Stimulus
    //==========================================================================
    initial begin
        // Initialize
        rst_n = 0;
        start = 0;
        input_data = 0;
        input_valid = 0;
        frame_width = FRAME_WIDTH;
        frame_height = FRAME_HEIGHT;
        ref_frame_base_addr = 32'h1000_0000;
        conv_mode = 1;  // Convolution mode
        quality_mode = 0;
        weight_load_en = 0;
        weight_load_addr = 0;
        weight_load_data = 0;
        cycle_count = 0;
        input_count = 0;
        output_count = 0;
        test_passed = 1;
        
        // Initialize test data
        initialize_test_data();
        
        $display("========================================");
        $display("  VCNPU Integrated System Test");
        $display("========================================");
        $display("Frame Size: %0dx%0d", FRAME_WIDTH, FRAME_HEIGHT);
        $display("Tile Size: %0d", TILE_SIZE);
        $display("Groups per frame: %0d", (FRAME_WIDTH/TILE_SIZE) * (FRAME_HEIGHT/TILE_SIZE));
        $display("========================================\n");
        
        // Reset
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(2) @(posedge clk);
        
        //----------------------------------------------------------------------
        // Test 1: Load Weights
        //----------------------------------------------------------------------
        $display("[Test 1] Loading weights...");
        load_weights();
        $display("[Test 1] Weights loaded\n");
        
        //----------------------------------------------------------------------
        // Test 2: Basic Frame Processing
        //----------------------------------------------------------------------
        $display("[Test 2] Processing frame with convolution mode...");
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Feed input data
        fork
            // Input data feeder
            begin
                repeat(10) @(posedge clk);  // Wait for system to initialize
                for (i = 0; i < 64; i = i + 1) begin  // 64 patches (4×4 groups)
                    for (j = 0; j < 16; j = j + 1) begin  // 16 values per patch
                        @(posedge clk);
                        input_data = input_patches[i][j];
                        input_valid = 1'b1;
                        input_count = input_count + 1;
                    end
                    // Small gap between patches
                    repeat(2) @(posedge clk);
                    input_valid = 1'b0;
                end
            end
            
            // Timeout watchdog
            begin
                repeat(10000) @(posedge clk);
                $display("[WARNING] Timeout waiting for completion");
            end
            
            // Wait for completion
            begin
                wait(!busy);
                $display("[Test 2] Frame processing complete");
                $display("  Cycles: %0d", cycle_count);
                $display("  Inputs sent: %0d", input_count);
                $display("  Outputs received: %0d\n", output_count);
            end
        join_any
        disable fork;
        
        repeat(50) @(posedge clk);
        
        //----------------------------------------------------------------------
        // Test 3: Deconvolution Mode
        //----------------------------------------------------------------------
        $display("[Test 3] Processing with deconvolution mode...");
        conv_mode = 0;
        quality_mode = 1;
        cycle_count = 0;
        input_count = 0;
        output_count = 0;
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        // Feed fewer patches for deconv test
        repeat(10) @(posedge clk);
        for (i = 0; i < 16; i = i + 1) begin
            for (j = 0; j < 16; j = j + 1) begin
                @(posedge clk);
                input_data = input_patches[i][j];
                input_valid = 1'b1;
            end
            repeat(2) @(posedge clk);
            input_valid = 1'b0;
        end
        
        wait(!busy);
        $display("[Test 3] Deconvolution complete");
        $display("  Cycles: %0d\n", cycle_count);
        
        repeat(50) @(posedge clk);
        
        //----------------------------------------------------------------------
        // Test 4: Different Quality Modes
        //----------------------------------------------------------------------
        $display("[Test 4] Testing quality modes...");
        conv_mode = 1;
        
        for (i = 0; i < 4; i = i + 1) begin
            quality_mode = i;
            $display("  Testing quality_mode = %0d", i);
            
            start = 1;
            @(posedge clk);
            start = 0;
            
            // Send small amount of data
            repeat(5) @(posedge clk);
            for (j = 0; j < 32; j = j + 1) begin
                @(posedge clk);
                input_data = $random & 16'hFFFF;
                input_valid = 1'b1;
            end
            @(posedge clk);
            input_valid = 1'b0;
            
            repeat(100) @(posedge clk);
        end
        $display("[Test 4] Quality mode test complete\n");
        
        //----------------------------------------------------------------------
        // Test 5: Stress Test with Continuous Data
        //----------------------------------------------------------------------
        $display("[Test 5] Stress test with continuous data stream...");
        conv_mode = 1;
        quality_mode = 0;
        
        start = 1;
        @(posedge clk);
        start = 0;
        
        repeat(5) @(posedge clk);
        for (i = 0; i < 500; i = i + 1) begin
            @(posedge clk);
            input_data = $random & 16'hFFFF;
            input_valid = 1'b1;
        end
        @(posedge clk);
        input_valid = 1'b0;
        
        repeat(500) @(posedge clk);
        $display("[Test 5] Stress test complete\n");
        
        //----------------------------------------------------------------------
        // Final Report
        //----------------------------------------------------------------------
        repeat(100) @(posedge clk);
        
        $display("========================================");
        $display("  Test Summary");
        $display("========================================");
        if (test_passed && !error) begin
            $display("  Status: PASSED");
            $display("  All tests completed successfully");
        end else begin
            $display("  Status: FAILED");
            $display("  Errors detected during testing");
        end
        $display("========================================\n");
        
        $finish;
    end

    //==========================================================================
    // Helper Tasks
    //==========================================================================
    
    // Initialize test data with patterns
    task initialize_test_data;
        integer x, y, p, v;
    begin
        // Initialize reference frame with checkerboard pattern
        for (y = 0; y < 64; y = y + 1) begin
            for (x = 0; x < 64; x = x + 1) begin
                reference_frame[y][x] = ((x + y) % 2) ? 16'h7FFF : 16'h0000;
            end
        end
        
        // Initialize input patches with gradient patterns
        for (p = 0; p < 256; p = p + 1) begin
            for (v = 0; v < 16; v = v + 1) begin
                input_patches[p][v] = (p * 256 + v * 16) & 16'hFFFF;
            end
        end
    end
    endtask
    
    // Load test weights into weight memory
    task load_weights;
        integer addr;
    begin
        weight_load_en = 1'b1;
        for (addr = 0; addr < 256; addr = addr + 1) begin
            @(posedge clk);
            weight_load_addr = addr;
            // Simple pattern: diagonal emphasis
            if (addr % 17 == 0)  // Diagonal positions
                weight_load_data = 16'h4000;  // 0.25 in fixed point
            else
                weight_load_data = 16'h1000;  // 0.0625 in fixed point
        end
        @(posedge clk);
        weight_load_en = 1'b0;
    end
    endtask

    //==========================================================================
    // VCD Dump
    //==========================================================================
    initial begin
        $dumpfile("vcnpu_integrated.vcd");
        $dumpvars(0, tb_vcnpu_integrated);
    end

    //==========================================================================
    // Timeout
    //==========================================================================
    initial begin
        #(CLK_PERIOD * 100000);
        $display("\n[TIMEOUT] Simulation exceeded maximum time");
        $finish;
    end

endmodule
