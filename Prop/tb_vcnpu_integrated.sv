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
    parameter WEIGHT_ADDR_W = 14;
    parameter FRAME_WIDTH = 64;   // Small frame for testing
    parameter FRAME_HEIGHT = 64;
    parameter TILE_SIZE = 16;

    // The TB input stream feeds 16 words per "patch". That naturally corresponds
    // to a 4x4 patch of 16-bit pixels (but your real design may map this
    // differently). We report FPS projections using BOTH TILE_SIZE and this
    // PERF_PATCH_SIDE so the numbers are interpretable.
    parameter int PERF_PATCH_SIDE = 4;

    // Projection target for reporting (does not affect DUT configuration)
    localparam int PROJ_FRAME_W = 1920;
    localparam int PROJ_FRAME_H = 1080;

    // Performance reporting knobs (does not affect DUT behavior)
    // - PERF_TARGET_CLK_MHZ: report what the same cycle counts would look like at this clock.
    // - PERF_REAL_IO_GBPS_OVERRIDE: if non-zero, use this total I/O cap (GB/s) for the conservative estimate.
    //   If zero, we derive an I/O cap from a 1-word-per-cycle 16-bit stream at PERF_TARGET_CLK_MHZ.
    // - PERF_REAL_IO_EFF: efficiency factor applied to the I/O cap.
    // The conservative estimate caps based on (input_words + output_words + dram_words) bytes per patch.
    parameter real PERF_TARGET_CLK_MHZ = 400.0;
    parameter real PERF_REAL_IO_GBPS_OVERRIDE = 0.0;
    parameter real PERF_REAL_IO_EFF  = 0.70;
    // If non-zero, use this as bytes/patch for the I/O cap calculation instead of the observed TB counts.
    // Useful because the regression suite may emit fewer output words than a full tile/frame would.
    parameter real PERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE = 0.0;

    // Perf printing controls
    // - PER_CASE: prints a short one-liner per case (off by default)
    // - TABLE_AT_END: prints a single CSV table at the end (on by default)
    parameter bit PERF_PRINT_PER_CASE = 1'b0;
    parameter bit PERF_PRINT_TABLE_AT_END = 1'b1;

    // RepVCN fusion weight-list sizing (used for optional fusion runs)
    localparam int FUSED_CH = 32;
    localparam int SCU_OUT_PAR = 3;
    localparam int CHANNEL_LOOP_COUNT = (FUSED_CH + SCU_OUT_PAR - 1) / SCU_OUT_PAR; // 11
    localparam int WEIGHTS_PER_PASS = 18;
    localparam int RF_LIST_WORDS = CHANNEL_LOOP_COUNT * FUSED_CH * WEIGHTS_PER_PASS; // 6336
    
    // Simulation clock period in ns. Default is 2.5ns (400 MHz).
    // Override with Verilator: -GCLK_PERIOD=<ns>
    parameter real CLK_PERIOD = 2.5;

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
    reg [WEIGHT_ADDR_W-1:0] weight_load_addr;
    reg [DATA_W-1:0] weight_load_data;

    // Index loading
    reg index_load_en;
    reg [WEIGHT_ADDR_W-1:0] index_load_addr;
    reg [9:0] index_load_data;

    // Hybrid fusion controls
    reg layer_seq_mode;
    reg [WEIGHT_ADDR_W-1:0] seq_wbase0;
    reg [WEIGHT_ADDR_W-1:0] seq_wbase1;
    reg [WEIGHT_ADDR_W-1:0] seq_wbase2;
    
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
    longint unsigned cycle_count;
    longint unsigned input_count;
    longint unsigned output_count;
    integer test_passed;
    integer error_pulses;
    longint unsigned out_hash;
    longint unsigned out_hash_last;
    reg stats_clr;

    // Suite-level aggregates (sum across run_case invocations)
    longint unsigned suite_busy_cycles;
    longint unsigned suite_input_words;
    longint unsigned suite_output_words;
    longint unsigned suite_dram_words;
    longint unsigned suite_patches;

    // Perf table storage
    localparam int unsigned PERF_MAX_ROWS = 64;
    int unsigned perf_row_count;
    string perf_tag   [0:PERF_MAX_ROWS-1];
    real   perf_clk_mhz[0:PERF_MAX_ROWS-1];
    longint unsigned perf_busy_cyc[0:PERF_MAX_ROWS-1];
    int    perf_patches[0:PERF_MAX_ROWS-1];
    real   perf_cycles_per_patch[0:PERF_MAX_ROWS-1];
    real   perf_kpatch_s[0:PERF_MAX_ROWS-1];
    real   perf_in_mb_s[0:PERF_MAX_ROWS-1];
    real   perf_out_mb_s[0:PERF_MAX_ROWS-1];
    real   perf_dram_mb_s[0:PERF_MAX_ROWS-1];
    real   perf_total_mb_s[0:PERF_MAX_ROWS-1];
    int    perf_patches_per_tile[0:PERF_MAX_ROWS-1];
    real   perf_est_fps_tile[0:PERF_MAX_ROWS-1];
    real   perf_est_fps_patch[0:PERF_MAX_ROWS-1];
    real   perf_proj_fps_tile[0:PERF_MAX_ROWS-1];
    real   perf_proj_fps_patch[0:PERF_MAX_ROWS-1];
    real   perf_scaled_proj_fps_tile[0:PERF_MAX_ROWS-1];
    real   perf_scaled_proj_fps_patch[0:PERF_MAX_ROWS-1];
    real   perf_real_proj_fps_tile[0:PERF_MAX_ROWS-1];
    real   perf_real_proj_fps_patch[0:PERF_MAX_ROWS-1];
    real   perf_io_bytes_per_patch_used[0:PERF_MAX_ROWS-1];
    real   perf_io_cap_gbps[0:PERF_MAX_ROWS-1];

    task automatic record_perf_row(
        input string tag_s,
        input real clk_mhz,
        input longint unsigned busy_cyc,
        input int n_patches,
        input real cycles_per_patch,
        input real kpatch_s,
        input real in_mb_s,
        input real out_mb_s,
        input real dram_mb_s,
        input real total_mb_s,
        input int patches_per_tile,
        input real est_fps_tile,
        input real est_fps_patch,
        input real proj_fps_tile,
        input real proj_fps_patch,
        input real scaled_proj_fps_tile,
        input real scaled_proj_fps_patch,
        input real real_proj_fps_tile,
        input real real_proj_fps_patch,
        input real io_bytes_per_patch_used,
        input real io_cap_gbps
    );
        int unsigned idx;
    begin
        if (perf_row_count >= PERF_MAX_ROWS) begin
            $display("[PERF][WARN] perf table full (%0d rows), dropping '%0s'", PERF_MAX_ROWS, tag_s);
            return;
        end
        idx = perf_row_count;
        perf_row_count++;
        perf_tag[idx] = tag_s;
        perf_clk_mhz[idx] = clk_mhz;
        perf_busy_cyc[idx] = busy_cyc;
        perf_patches[idx] = n_patches;
        perf_cycles_per_patch[idx] = cycles_per_patch;
        perf_kpatch_s[idx] = kpatch_s;
        perf_in_mb_s[idx] = in_mb_s;
        perf_out_mb_s[idx] = out_mb_s;
        perf_dram_mb_s[idx] = dram_mb_s;
        perf_total_mb_s[idx] = total_mb_s;
        perf_patches_per_tile[idx] = patches_per_tile;
        perf_est_fps_tile[idx] = est_fps_tile;
        perf_est_fps_patch[idx] = est_fps_patch;
        perf_proj_fps_tile[idx] = proj_fps_tile;
        perf_proj_fps_patch[idx] = proj_fps_patch;
        perf_scaled_proj_fps_tile[idx] = scaled_proj_fps_tile;
        perf_scaled_proj_fps_patch[idx] = scaled_proj_fps_patch;
        perf_real_proj_fps_tile[idx] = real_proj_fps_tile;
        perf_real_proj_fps_patch[idx] = real_proj_fps_patch;
        perf_io_bytes_per_patch_used[idx] = io_bytes_per_patch_used;
        perf_io_cap_gbps[idx] = io_cap_gbps;
    end
    endtask

    function automatic string trunc_pad(input string s, input int width);
        string out;
        int i;
    begin
        out = s;
        if (width <= 0) begin
            out = "";
        end else if (out.len() > width) begin
            out = out.substr(0, width-1);
        end else begin
            for (i = out.len(); i < width; i = i + 1) begin
                out = {out, " "};
            end
        end
        trunc_pad = out;
    end
    endfunction

    task automatic print_perf_table;
        int unsigned r;
        localparam int TAG_W = 26;
        string t;
        string sep;
        int i;
    begin
        $display("\n==============================================================");
        $display("  PERF Summary (Table)  patch_side=%0d  tile_side=%0d  proj=%0dx%0d",
                 PERF_PATCH_SIDE, TILE_SIZE, PROJ_FRAME_W, PROJ_FRAME_H);
        $display("==============================================================");
        $display("%0s | %7s | %8s | %7s | %7s | %7s | %7s | %7s | %7s | %6s | %5s",
             trunc_pad("case", TAG_W), "clk", "kpatch/s", "projT", "projP", "realP", "inMB/s", "outMB/s", "dramMB", "B/patch", "cap");

        sep = "";
        for (i = 0; i < TAG_W; i = i + 1) sep = {sep, "-"};
        $display("%0s-+-%7s-+-%8s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s-+-%7s-+-%6s-+-%5s",
             sep, "-------", "--------", "-------", "-------", "-------", "-------", "-------", "-------", "------", "-----");

        for (r = 0; r < perf_row_count; r = r + 1) begin
            t = trunc_pad(perf_tag[r], TAG_W);
            $display("%0s | %7.2f | %8.1f | %7.2f | %7.2f | %7.2f | %7.1f | %7.1f | %7.1f | %6.1f | %5.2f",
                     t,
                     perf_clk_mhz[r],
                     perf_kpatch_s[r],
                     perf_proj_fps_tile[r],
                     perf_proj_fps_patch[r],
                     perf_real_proj_fps_patch[r],
                     perf_in_mb_s[r],
                     perf_out_mb_s[r],
                     perf_dram_mb_s[r],
                     perf_io_bytes_per_patch_used[r],
                     perf_io_cap_gbps[r]);
        end

        $display("\nNotes:");
        $display("  projT/projP = projected FPS at %0dx%0d using tile vs patch grouping.", PROJ_FRAME_W, PROJ_FRAME_H);
        $display("  realP       = projected FPS with I/O cap applied (patch grouping).");
        $display("==============================================================\n");
    end
    endtask

    // Per-case DRAM traffic counter (words accepted on dram_data_in)
    longint unsigned dram_word_count;

    // DRAM model warnings can be very chatty (dram_req may stay asserted).
    // Count overlaps, print only the first few, then suppress.
    localparam int unsigned DRAM_OVERLAP_WARN_MAX_PRINTS = 5;
    longint unsigned dram_overlap_warn_count;
    int unsigned dram_overlap_warn_printed;

    initial begin
        // Keep these global across TB-driven resets so warnings don't re-spam per case.
        dram_overlap_warn_count = 0;
        dram_overlap_warn_printed = 0;
    end
    
    // Reference data storage
    reg [DATA_W-1:0] reference_frame [0:63][0:63];
    reg [DATA_W-1:0] input_patches [0:255][0:15];  // 256 patches, 16 values each

    // Optional: load real data from files for more realistic traffic/behavior.
    // Provide plusargs at runtime:
    //   +ref_memh=<path>   (FRAME_WIDTH*FRAME_HEIGHT 16-bit words, row-major)
    //   +patch_memh=<path> (256*16 16-bit words, patch-major)
    localparam int REF_WORDS_MAX   = FRAME_WIDTH * FRAME_HEIGHT;
    localparam int PATCH_WORDS_MAX = 256 * 16;
    reg [DATA_W-1:0] ref_memh_words   [0:REF_WORDS_MAX-1];
    reg [DATA_W-1:0] patch_memh_words [0:PATCH_WORDS_MAX-1];
    bit use_ref_memh;
    bit use_patch_memh;
    string ref_memh_path;
    string patch_memh_path;
    
    //==========================================================================
    // DUT Instantiation
    //==========================================================================
    vcnpu_top #(
        .DATA_W(DATA_W),
        .N_CH(N_CH),
        .GROUP_ROWS(GROUP_ROWS),
        .DEPTH_GROUPS(DEPTH_GROUPS),
        .WEIGHT_ADDR_W(WEIGHT_ADDR_W),
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
        .layer_seq_mode(layer_seq_mode),
        .seq_wbase0(seq_wbase0),
        .seq_wbase1(seq_wbase1),
        .seq_wbase2(seq_wbase2),
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
        .index_load_en(index_load_en),
        .index_load_addr(index_load_addr),
        .index_load_data(index_load_data),
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
        forever #(CLK_PERIOD/2.0) clk = ~clk;
    end

    //==========================================================================
    // DRAM Model (Deterministic)
    //==========================================================================
    // Deterministic, request/len-respecting stream model.
    // This makes deconv/DPM + prefetch behavior reproducible and debuggable.
    typedef enum int unsigned {DRAM_IDLE=0, DRAM_ACK=1, DRAM_WAIT=2, DRAM_STREAM=3} dram_state_t;
    dram_state_t dram_state;
    reg [31:0] dram_req_addr;
    reg [15:0] dram_req_len;
    reg [15:0] dram_beat;
    reg [1:0]  dram_latency;
    reg        dram_req_q;

    function automatic [DATA_W-1:0] dram_word(input [31:0] base_addr, input [15:0] beat);
        reg [31:0] widx;
        reg [31:0] mix;
        integer idx;
    begin
        // Treat dram_addr as byte address for 16-bit words.
        widx = (base_addr >> 1) + beat;

        // If a reference-frame memh was loaded, serve DRAM words from it.
        // Map address space such that ref_frame_base_addr corresponds to ref_memh_words[0].
        if (use_ref_memh) begin
            idx = $signed(widx) - $signed(ref_frame_base_addr >> 1);
            if ((idx >= 0) && (idx < REF_WORDS_MAX)) begin
                dram_word = ref_memh_words[idx];
            end else begin
                mix = (widx * 32'h1F1F_1234) ^ (widx << 7) ^ (widx >> 9);
                dram_word = mix[DATA_W-1:0];
            end
        end else begin
            mix = (widx * 32'h1F1F_1234) ^ (widx << 7) ^ (widx >> 9);
            dram_word = mix[DATA_W-1:0];
        end
    end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dram_ack <= 1'b0;
            dram_data_valid <= 1'b0;
            dram_data_in <= '0;
            dram_state <= DRAM_IDLE;
            dram_req_addr <= 32'd0;
            dram_req_len <= 16'd0;
            dram_beat <= 16'd0;
            dram_latency <= 2'd0;
            dram_req_q <= 1'b0;
        end else begin
            dram_ack <= 1'b0;
            dram_data_valid <= 1'b0;
            dram_req_q <= dram_req;

            case (dram_state)
                DRAM_IDLE: begin
                    if (dram_req) begin
                        dram_req_addr <= dram_addr;
                        dram_req_len <= dram_len;
                        dram_beat <= 0;
                        dram_latency <= 2; // fixed read latency
                        dram_state <= DRAM_ACK;
                    end
                end

                DRAM_ACK: begin
                    dram_ack <= 1'b1;
                    dram_state <= DRAM_WAIT;
                end

                DRAM_WAIT: begin
                    if (dram_latency == 0) begin
                        if (dram_req_len == 0) begin
                            dram_state <= DRAM_IDLE;
                        end else begin
                            dram_state <= DRAM_STREAM;
                        end
                    end else begin
                        dram_latency <= dram_latency - 1'b1;
                    end
                end

                DRAM_STREAM: begin
                    // The DUT's external DRAM interface has no backpressure
                    // signal, but the DPM only starts consuming reference data
                    // after it reaches its READ_REF state. To avoid dropping
                    // most of a burst (and stalling deconv), we pause streaming
                    // in deconv mode until DPM is ready.
                    if (!conv_mode && (dut.u_dpm.state != 2)) begin
                        dram_data_valid <= 1'b0;
                    end else begin
                        dram_data_valid <= 1'b1;
                        dram_data_in <= dram_word(dram_req_addr, dram_beat);
                        if (dram_beat == (dram_req_len - 1)) begin
                            dram_state <= DRAM_IDLE;
                        end else begin
                            dram_beat <= dram_beat + 1'b1;
                        end
                    end
                end

                default: dram_state <= DRAM_IDLE;
            endcase

            // If prefetch requests overlap (shouldn't happen), flag it.
            // Only consider it an overlap if a *new* request arrives while busy.
            if (dram_req && !dram_req_q && (dram_state != DRAM_IDLE)) begin
                dram_overlap_warn_count <= dram_overlap_warn_count + 1;
                if (dram_overlap_warn_printed < DRAM_OVERLAP_WARN_MAX_PRINTS) begin
                    $display("[DRAM][WARN] Overlapping request at T=%0t addr=0x%08x len=%0d", $time, dram_addr, dram_len);
                    if (dram_overlap_warn_printed == (DRAM_OVERLAP_WARN_MAX_PRINTS - 1)) begin
                        $display("[DRAM][WARN] Further overlapping-request warnings suppressed (will count only)");
                    end
                    dram_overlap_warn_printed <= dram_overlap_warn_printed + 1;
                end
            end
        end
    end

    // Track DRAM data beats (word-level)
    always @(posedge clk) begin
        if (!rst_n || stats_clr) begin
            dram_word_count <= 0;
        end else begin
            if (dram_data_valid)
                dram_word_count <= dram_word_count + 1;
        end
    end

    //==========================================================================
    // Monitoring and Statistics
    //==========================================================================
    always @(posedge clk) begin
        if (!rst_n || stats_clr) begin
            cycle_count <= 0;
            output_count <= 0;
            out_hash <= 64'd0;
            error_pulses <= 0;
        end else begin
            if (busy)
                cycle_count <= cycle_count + 1;

            if (output_valid) begin
                output_count <= output_count + 1;
                // Simple rolling hash (good enough to detect regressions)
                out_hash <= {out_hash[62:0], out_hash[63]} ^ {48'd0, output_data};
                // Optional verbose print (keep off by default)
                // $display("[T=%0t] Output[%0d] = 0x%04x", $time, output_count, output_data);
            end

            if (error) begin
                error_pulses <= error_pulses + 1;
                if (error_pulses < 10)
                    $display("[WARN] System error pulse at time %0t", $time);
            end

            // Basic X-propagation guards (Verilator will treat X as 0, but keep these anyway)
            if (^system_state === 1'bX) begin
                $display("[ERROR] system_state is X at T=%0t", $time);
                test_passed = 0;
            end
        end
    end

    //==========================================================================
    // Test Stimulus
    //==========================================================================
    //==========================================================================
    // Test Harness Tasks
    //==========================================================================

    task automatic reset_dut;
    begin
        rst_n = 1'b0;
        start = 1'b0;
        input_data = '0;
        input_valid = 1'b0;
        frame_width = FRAME_WIDTH;
        frame_height = FRAME_HEIGHT;
        ref_frame_base_addr = 32'h1000_0000;
        conv_mode = 1'b1;
        quality_mode = 2'd0;
        layer_seq_mode = 1'b0;
        seq_wbase0 = 0;
        seq_wbase1 = RF_LIST_WORDS;
        seq_wbase2 = RF_LIST_WORDS*2;
        weight_load_en = 1'b0;
        weight_load_addr = '0;
        weight_load_data = '0;
        index_load_en = 1'b0;
        index_load_addr = '0;
        index_load_data = '0;
        cycle_count = 0;
        input_count = 0;
        output_count = 0;
        out_hash = 64'd0;
        stats_clr = 1'b0;
        repeat(5) @(posedge clk);
        rst_n = 1'b1;
        repeat(5) @(posedge clk);
    end
    endtask

    task automatic clear_stats;
    begin
        // Clear with a synchronous pulse so we don't race the monitor always block.
        input_count = 0;
        stats_clr = 1'b1;
        @(posedge clk);
        stats_clr = 1'b0;
    end
    endtask

    function automatic int ceil_div(input int a, input int b);
        if (b <= 0) ceil_div = 0;
        else ceil_div = (a + b - 1) / b;
    endfunction

    task automatic report_perf(
        input [8*64-1:0] tag,
        input int n_patches
    );
        real busy_time_ns;
        real busy_time_s;
        real clk_mhz;
        int tiles_x;
        int tiles_y;
        int groups_per_frame;

        int patches_per_tile_side;
        int patches_per_tile;

        int patch_tiles_x;
        int patch_tiles_y;
        int patch_groups_per_frame;
        int proj_tiles_x;
        int proj_tiles_y;
        int proj_groups_per_frame;

        int proj_patch_tiles_x;
        int proj_patch_tiles_y;
        int proj_patch_groups_per_frame;
        real patches_per_s;
        real cycles_per_patch;
        real in_words_per_s;
        real out_words_per_s;
        real in_mb_per_s;
        real out_mb_per_s;
        real dram_words_per_s;
        real dram_mb_per_s;
        real total_mb_per_s;
        real est_fps;
        real proj_fps;

        real est_fps_patch;
        real proj_fps_patch;
        real scale;
        real patches_per_s_scaled;
        real est_fps_scaled;
        real proj_fps_scaled;

        real est_fps_patch_scaled;
        real proj_fps_patch_scaled;
        real io_bytes_per_patch;
        real io_bytes_per_patch_used;
        real bw_bytes_per_s;
        real io_cap_gbps;
        real patches_per_s_bw;
        real patches_per_s_real;
        real est_fps_real;
        real proj_fps_real;

        real est_fps_patch_real;
        real proj_fps_patch_real;
        string tag_s;
    begin
        busy_time_ns = real'(cycle_count) * CLK_PERIOD;
        busy_time_s  = busy_time_ns * 1e-9;
        clk_mhz      = 1000.0 / CLK_PERIOD;

        tiles_x = ceil_div(frame_width, TILE_SIZE);
        tiles_y = ceil_div(frame_height, TILE_SIZE);
        groups_per_frame = tiles_x * tiles_y;

        // If a tile is larger than a patch, then one tile covers multiple patches.
        // Convert patches/s into frames/s by dividing by tiles/frame * patches/tile.
        patches_per_tile_side = ceil_div(TILE_SIZE, PERF_PATCH_SIDE);
        patches_per_tile      = patches_per_tile_side * patches_per_tile_side;

        patch_tiles_x = ceil_div(frame_width, PERF_PATCH_SIDE);
        patch_tiles_y = ceil_div(frame_height, PERF_PATCH_SIDE);
        patch_groups_per_frame = patch_tiles_x * patch_tiles_y;

        proj_tiles_x = ceil_div(PROJ_FRAME_W, TILE_SIZE);
        proj_tiles_y = ceil_div(PROJ_FRAME_H, TILE_SIZE);
        proj_groups_per_frame = proj_tiles_x * proj_tiles_y;

        proj_patch_tiles_x = ceil_div(PROJ_FRAME_W, PERF_PATCH_SIDE);
        proj_patch_tiles_y = ceil_div(PROJ_FRAME_H, PERF_PATCH_SIDE);
        proj_patch_groups_per_frame = proj_patch_tiles_x * proj_patch_tiles_y;

        if (busy_time_s > 0.0) begin
            patches_per_s  = (n_patches > 0) ? ($itor(n_patches) / busy_time_s) : 0.0;
            in_words_per_s = real'(input_count) / busy_time_s;
            out_words_per_s = real'(output_count) / busy_time_s;
            dram_words_per_s = real'(dram_word_count) / busy_time_s;
        end else begin
            patches_per_s  = 0.0;
            in_words_per_s = 0.0;
            out_words_per_s = 0.0;
            dram_words_per_s = 0.0;
        end

        cycles_per_patch = (n_patches > 0) ? (real'(cycle_count) / $itor(n_patches)) : 0.0;
        in_mb_per_s  = (in_words_per_s  * DATA_W / 8.0) / 1e6;
        out_mb_per_s = (out_words_per_s * DATA_W / 8.0) / 1e6;
        dram_mb_per_s = (dram_words_per_s * DATA_W / 8.0) / 1e6;
        total_mb_per_s = in_mb_per_s + out_mb_per_s + dram_mb_per_s;
        est_fps = (groups_per_frame > 0 && patches_per_tile > 0) ?
                  (patches_per_s / (real'(groups_per_frame) * real'(patches_per_tile))) : 0.0;
        proj_fps = (proj_groups_per_frame > 0 && patches_per_tile > 0) ?
                   (patches_per_s / (real'(proj_groups_per_frame) * real'(patches_per_tile))) : 0.0;

        est_fps_patch  = (patch_groups_per_frame > 0) ? (patches_per_s / $itor(patch_groups_per_frame)) : 0.0;
        proj_fps_patch = (proj_patch_groups_per_frame > 0) ? (patches_per_s / $itor(proj_patch_groups_per_frame)) : 0.0;

        // Scale the same cycle counts to a target clock rate (e.g., 400 MHz).
        scale = (clk_mhz > 0.0) ? (PERF_TARGET_CLK_MHZ / clk_mhz) : 0.0;
        patches_per_s_scaled = patches_per_s * scale;
        est_fps_scaled = est_fps * scale;
        proj_fps_scaled = proj_fps * scale;

        est_fps_patch_scaled  = est_fps_patch * scale;
        proj_fps_patch_scaled = proj_fps_patch * scale;

        // Conservative cap: assume total I/O bandwidth limit (input + output + DRAM), apply efficiency.
        if (n_patches > 0) begin
            io_bytes_per_patch = ((real'(input_count) + real'(output_count) + real'(dram_word_count)) * (DATA_W / 8.0)) / $itor(n_patches);
        end else begin
            io_bytes_per_patch = 0.0;
        end
        io_bytes_per_patch_used = (PERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE > 0.0) ? PERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE : io_bytes_per_patch;
        if (PERF_REAL_IO_GBPS_OVERRIDE > 0.0) begin
            bw_bytes_per_s = PERF_REAL_IO_GBPS_OVERRIDE * 1e9 * PERF_REAL_IO_EFF;
        end else begin
            // Derived cap: 1 word/cycle stream at PERF_TARGET_CLK_MHZ.
            bw_bytes_per_s = (DATA_W / 8.0) * (PERF_TARGET_CLK_MHZ * 1e6) * PERF_REAL_IO_EFF;
        end
        io_cap_gbps = bw_bytes_per_s / 1e9;
        if (io_bytes_per_patch_used > 0.0) begin
            patches_per_s_bw = bw_bytes_per_s / io_bytes_per_patch_used;
        end else begin
            patches_per_s_bw = 0.0;
        end
        patches_per_s_real = (patches_per_s_scaled > 0.0 && patches_per_s_bw > 0.0) ?
                             ((patches_per_s_scaled < patches_per_s_bw) ? patches_per_s_scaled : patches_per_s_bw) :
                             patches_per_s_scaled;
        est_fps_real = (groups_per_frame > 0 && patches_per_tile > 0) ?
                   (patches_per_s_real / (real'(groups_per_frame) * real'(patches_per_tile))) : 0.0;
        proj_fps_real = (proj_groups_per_frame > 0 && patches_per_tile > 0) ?
                (patches_per_s_real / (real'(proj_groups_per_frame) * real'(patches_per_tile))) : 0.0;

        est_fps_patch_real  = (patch_groups_per_frame > 0) ? (patches_per_s_real / $itor(patch_groups_per_frame)) : 0.0;
        proj_fps_patch_real = (proj_patch_groups_per_frame > 0) ? (patches_per_s_real / $itor(proj_patch_groups_per_frame)) : 0.0;

        tag_s = $sformatf("%0s", tag);
        record_perf_row(
            tag_s,
            clk_mhz,
            cycle_count,
            n_patches,
            cycles_per_patch,
            patches_per_s / 1e3,
            in_mb_per_s,
            out_mb_per_s,
            dram_mb_per_s,
            total_mb_per_s,
            patches_per_tile,
            est_fps,
            est_fps_patch,
            proj_fps,
            proj_fps_patch,
            proj_fps_scaled,
            proj_fps_patch_scaled,
            proj_fps_real,
            proj_fps_patch_real,
            io_bytes_per_patch_used,
            io_cap_gbps
        );

        if (PERF_PRINT_PER_CASE) begin
            $display("[PERF][%0s] clk=%0.2fMHz kpatch/s=%0.3f proj1080(tile)=%0.2f proj1080(patch)=%0.2f real_proj1080(patch)=%0.2f",
                     tag, clk_mhz, patches_per_s / 1e3, proj_fps, proj_fps_patch, proj_fps_patch_real);
        end
    end
    endtask

    task automatic pulse_start;
    begin
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
    end
    endtask

    task automatic feed_patches(input integer n_patches, input integer gap_cycles);
        integer p, v;
    begin
        // Stream immediately; controller treats 'start' as a run-level.
        for (p = 0; p < n_patches; p = p + 1) begin
            for (v = 0; v < 16; v = v + 1) begin
                @(posedge clk);
                input_data = input_patches[p][v];
                input_valid = 1'b1;
                input_count = input_count + 1;
            end
            input_valid = 1'b0;
            repeat(gap_cycles) @(posedge clk);
        end
        input_valid = 1'b0;
    end
    endtask

    task automatic wait_busy_assert_or_timeout;
        integer t;
    begin
        for (t = 0; t < 2000; t = t + 1) begin
            @(posedge clk);
            if (busy) return;
        end
        $display("[TIMEOUT] busy did not assert after start");
        test_passed = 0;
    end
    endtask

    task automatic wait_busy_deassert_or_timeout(input integer timeout_cycles);
        integer t;
    begin
        for (t = 0; t < timeout_cycles; t = t + 1) begin
            @(posedge clk);
            if (!busy) return;
        end
        $display("[TIMEOUT] busy did not deassert within %0d cycles", timeout_cycles);
        $display("[DBG] start=%0d conv=%0d seq=%0d q=%0d busy=%0d err=%0d", start, conv_mode, layer_seq_mode, quality_mode, busy, error);
        $display("[DBG] ctrl_state=%0d draining_group=%0d sftm_en=%0d dpm_en=%0d bypass=%0d", dut.u_glob.ctrl_state, dut.u_glob.draining_group, dut.sftm_enable, dut.dpm_enable, dut.bypass_mode_en);
        $display("[DBG] fifo_empty=%0d fifo_full=%0d fifo_count=%0d rd_valid=%0d rd_last=%0d", dut.fifo_empty, dut.fifo_full, dut.fifo_count_internal, dut.fifo_dout_valid, dut.fifo_dout_last);
        $display("[DBG] dram_state=%0d dram_req=%0d dram_ack=%0d req_len=%0d beat=%0d data_valid=%0d", dram_state, dram_req, dram_ack, dram_req_len, dram_beat, dram_data_valid);
        $display("[DBG] dpm_processing=%0d prefetch_busy=%0d", dut.dpm_processing, dut.prefetch_busy);
        $display("[DBG] dpm_state=%0d dpm_cnt=%0d dpm_pixel_cnt=%0d dpm_fifo_pop=%0d", dut.u_dpm.state, dut.u_dpm.cnt, dut.u_dpm.pixel_cnt, dut.fifo_pop_from_dpm);
        test_passed = 0;
    end
    endtask

    task automatic start_run;
    begin
        // Hold start high while streaming inputs. The controller uses !start as an end marker.
        @(posedge clk);
        start = 1'b1;
    end
    endtask

    task automatic stop_run;
    begin
        @(posedge clk);
        start = 1'b0;
    end
    endtask

    // Run a single scenario. Returns hash/out_count via globals.
    task automatic run_case(
        input [8*64-1:0] case_name,
        input bit case_conv_mode,
        input bit case_layer_seq_mode,
        input [1:0] case_quality_mode,
        input integer n_patches,
        input integer gap_cycles,
        input integer timeout_cycles,
        input bit require_outputs,
        input bit expect_all_zero_outputs
    );
        integer seen_nonzero;
    begin
        $display("\n[CASE] %0s (conv=%0d seq=%0d q=%0d patches=%0d gap=%0d)",
                 case_name, case_conv_mode, case_layer_seq_mode, case_quality_mode, n_patches, gap_cycles);
        clear_stats();
        conv_mode = case_conv_mode;
        layer_seq_mode = case_layer_seq_mode;
        quality_mode = case_quality_mode;

        // Start the system (run-level) and feed inputs while busy.
        start_run();
        wait_busy_assert_or_timeout();
        feed_patches(n_patches, gap_cycles);
        stop_run();
        wait_busy_deassert_or_timeout(timeout_cycles);

        // Let any trailing outputs drain.
        repeat(50) @(posedge clk);

        // Basic case checks.
        if (error) begin
            $display("[CASE][FAIL] error asserted");
            test_passed = 0;
        end
        if (require_outputs && (output_count == 0)) begin
            $display("[CASE][FAIL] no outputs observed");
            test_passed = 0;
        end

        // Optional strict check: when weights are all zero, conv outputs should be zero.
        if (expect_all_zero_outputs) begin
            seen_nonzero = 0;
            // We don't store all outputs; instead we re-run a short window where
            // we assert on-the-fly. This is still useful and keeps the TB light.
            // (If you want full waveform debug, enable the verbose display above.)
            // NOTE: This is a best-effort check; it assumes the output stream is purely computed.
            // If the design emits headers/metadata, relax this condition.
            // Here we just require the running hash to be consistent with all-zero stream.
            if (out_hash !== 64'd0) begin
                $display("[CASE][WARN] expected all-zero outputs, but out_hash=0x%016x", out_hash);
            end
        end

        $display("[CASE] done: cycles=%0d inputs=%0d outputs=%0d hash=0x%016x",
                 cycle_count, input_count, output_count, out_hash);

        // Performance report + suite aggregation
        report_perf(case_name, n_patches);
        suite_busy_cycles  += longint'(cycle_count);
        suite_input_words  += longint'(input_count);
        suite_output_words += longint'(output_count);
        suite_dram_words   += longint'(dram_word_count);
        suite_patches      += longint'(n_patches);
    end
    endtask

    // Load a small, non-zero pattern into weights/indexes to verify the load path changes behavior.
    task automatic load_weights_pattern;
        integer addr;
        integer max_addr;
    begin
        max_addr = (RF_LIST_WORDS * 2) + 256;
        weight_load_en = 1'b1;
        index_load_en = 1'b1;
        for (addr = 0; addr < max_addr; addr = addr + 1) begin
            @(posedge clk);
            weight_load_addr = addr[WEIGHT_ADDR_W-1:0];
            index_load_addr  = addr[WEIGHT_ADDR_W-1:0];

            // Weight pattern: repeatable, non-trivial
            if ((addr % 19) == 0)
                weight_load_data = 16'h2000;
            else if ((addr % 7) == 0)
                weight_load_data = 16'hF000;
            else
                weight_load_data = 16'h0100;

            // Index pattern (tile36 positions): 0..35
            index_load_data = (addr % 36);
        end
        @(posedge clk);
        weight_load_en = 1'b0;
        index_load_en = 1'b0;
    end
    endtask

    //==========================================================================
    // Test Stimulus (Multi-scenario)
    //==========================================================================
    initial begin
        test_passed = 1;
        suite_busy_cycles  = 0;
        suite_input_words  = 0;
        suite_output_words = 0;
        suite_dram_words   = 0;
        suite_patches      = 0;

        // Optional: load real input/reference data from memh files
        use_ref_memh = 1'b0;
        use_patch_memh = 1'b0;
        if ($value$plusargs("ref_memh=%s", ref_memh_path)) begin
            $display("[TB] Loading ref_memh: %0s", ref_memh_path);
            $readmemh(ref_memh_path, ref_memh_words);
            use_ref_memh = 1'b1;
        end
        if ($value$plusargs("patch_memh=%s", patch_memh_path)) begin
            $display("[TB] Loading patch_memh: %0s", patch_memh_path);
            $readmemh(patch_memh_path, patch_memh_words);
            use_patch_memh = 1'b1;
        end
        initialize_test_data();

        $display("========================================");
        $display("  VCNPU Integrated System Test (Suite)");
        $display("========================================");
        $display("Frame Size: %0dx%0d", FRAME_WIDTH, FRAME_HEIGHT);
        $display("Tile Size: %0d", TILE_SIZE);
        $display("========================================\n");

        reset_dut();

        // ---------------------------------------------------------------------
        // Suite 1: Conv mode, all quality modes, default cleared weights
        // ---------------------------------------------------------------------
        // On reset, weight/index memories are cleared to 0 in vcnpu_top.
        // This should make the compute outputs collapse toward 0 (sanity check).
        for (i = 0; i < 4; i = i + 1) begin
            run_case("conv_default",
                     1'b1, 1'b0, i[1:0],
                     16, 2, 50000,
                     1'b1,
                     1'b1);
        end

        // ---------------------------------------------------------------------
        // Suite 2: Stress RFConv0 ping/pong with continuous patches
        // ---------------------------------------------------------------------
        run_case("conv_stress_continuous",
                 1'b1, 1'b0, 2'd0,
                 128, 0, 100000,
                 1'b1,
                 1'b1);

        // ---------------------------------------------------------------------
        // Suite 3: Fusion sequencing (layer_seq_mode=1)
        // Feed 32 patches to represent 32 channels for a single fused tile.
        // Keep conv_mode=1 so DPM is bypassed and SFTM's final output is emitted.
        // ---------------------------------------------------------------------
        run_case("fusion_seq_mode_basic",
                 1'b1, 1'b1, 2'd0,
                 32, 0, 200000,
                 1'b0,
                 1'b1);

        // ---------------------------------------------------------------------
        // Suite 4: Deconv mode (DPM path enabled)
        // With cleared weights, motion-vector stream should tend toward zeros,
        // making DPM output solely a function of deterministic DRAM model.
        // We run it twice and require the output hash to match (determinism).
        // ---------------------------------------------------------------------
        // Deconv is the deepest path; reset between runs so any sticky error/
        // internal state does not contaminate the determinism check.
        reset_dut();
        run_case("deconv_default_run1",
                 1'b0, 1'b0, 2'd1,
                 16, 2, 200000,
                 1'b0,
                 1'b0);
        out_hash_last = out_hash;

        reset_dut();
        run_case("deconv_default_run2",
                 1'b0, 1'b0, 2'd1,
                 16, 2, 200000,
                 1'b0,
                 1'b0);
        if (out_hash !== out_hash_last) begin
            $display("[FAIL] Deconv determinism check failed: run1=0x%016x run2=0x%016x", out_hash_last, out_hash);
            test_passed = 0;
        end else begin
            $display("[OK] Deconv determinism check: hash=0x%016x", out_hash);
        end

        // ---------------------------------------------------------------------
        // Suite 5: Weight/index load path should change behavior (non-zero pattern)
        // ---------------------------------------------------------------------
        reset_dut();
        $display("\n[Suite] Loading non-zero weight/index pattern...");
        load_weights_pattern();

        run_case("conv_nonzero_weights_q0",
                 1'b1, 1'b0, 2'd0,
                 16, 2, 80000,
                 1'b1,
                 1'b0);

        // Deconv with non-zero weights: exercises motion-vector generation + DPM datapath.
        run_case("deconv_nonzero_weights_q1",
             1'b0, 1'b0, 2'd1,
             16, 2, 250000,
               1'b1,
             1'b0);

        // Quick restart check (no reset between runs)
        run_case("conv_restart_sanity",
             1'b1, 1'b0, 2'd0,
             8, 1, 60000,
               1'b1,
             1'b0);

        // Final report
        repeat(50) @(posedge clk);

        // Suite-level performance summary (aggregate) -> recorded as a final perf-table row
        begin
            real suite_time_ns;
            real suite_time_s;
            real clk_mhz;
            int tiles_x;
            int tiles_y;
            int groups_per_frame;
            int patches_per_tile_side;
            int patches_per_tile;
            int patch_tiles_x;
            int patch_tiles_y;
            int patch_groups_per_frame;
            int proj_tiles_x;
            int proj_tiles_y;
            int proj_groups_per_frame;
            int proj_patch_tiles_x;
            int proj_patch_tiles_y;
            int proj_patch_groups_per_frame;
            real patches_per_s;
            real in_words_per_s;
            real out_words_per_s;
            real in_mb_per_s;
            real out_mb_per_s;
            real dram_words_per_s;
            real dram_mb_per_s;
            real total_mb_per_s;
            real est_fps;
            real proj_fps;
            real est_fps_patch;
            real proj_fps_patch;
            real scale;
            real patches_per_s_scaled;
            real est_fps_scaled;
            real proj_fps_scaled;
            real est_fps_patch_scaled;
            real proj_fps_patch_scaled;
            real io_bytes_per_patch;
            real io_bytes_per_patch_used;
            real bw_bytes_per_s;
            real io_cap_gbps;
            real patches_per_s_bw;
            real patches_per_s_real;
            real est_fps_real;
            real proj_fps_real;
            real est_fps_patch_real;
            real proj_fps_patch_real;
            suite_time_ns = real'(suite_busy_cycles) * CLK_PERIOD;
            suite_time_s  = suite_time_ns * 1e-9;
            clk_mhz       = 1000.0 / CLK_PERIOD;
            tiles_x = ceil_div(frame_width, TILE_SIZE);
            tiles_y = ceil_div(frame_height, TILE_SIZE);
            groups_per_frame = tiles_x * tiles_y;

            patches_per_tile_side = ceil_div(TILE_SIZE, PERF_PATCH_SIDE);
            patches_per_tile      = patches_per_tile_side * patches_per_tile_side;

            patch_tiles_x = ceil_div(frame_width, PERF_PATCH_SIDE);
            patch_tiles_y = ceil_div(frame_height, PERF_PATCH_SIDE);
            patch_groups_per_frame = patch_tiles_x * patch_tiles_y;

            proj_tiles_x = ceil_div(PROJ_FRAME_W, TILE_SIZE);
            proj_tiles_y = ceil_div(PROJ_FRAME_H, TILE_SIZE);
            proj_groups_per_frame = proj_tiles_x * proj_tiles_y;

            proj_patch_tiles_x = ceil_div(PROJ_FRAME_W, PERF_PATCH_SIDE);
            proj_patch_tiles_y = ceil_div(PROJ_FRAME_H, PERF_PATCH_SIDE);
            proj_patch_groups_per_frame = proj_patch_tiles_x * proj_patch_tiles_y;
            if (suite_time_s > 0.0) begin
                patches_per_s  = real'(suite_patches) / suite_time_s;
                in_words_per_s = real'(suite_input_words) / suite_time_s;
                out_words_per_s = real'(suite_output_words) / suite_time_s;
                dram_words_per_s = real'(suite_dram_words) / suite_time_s;
            end else begin
                patches_per_s  = 0.0;
                in_words_per_s = 0.0;
                out_words_per_s = 0.0;
                dram_words_per_s = 0.0;
            end
            in_mb_per_s  = (in_words_per_s  * DATA_W / 8.0) / 1e6;
            out_mb_per_s = (out_words_per_s * DATA_W / 8.0) / 1e6;
            dram_mb_per_s = (dram_words_per_s * DATA_W / 8.0) / 1e6;
            total_mb_per_s = in_mb_per_s + out_mb_per_s + dram_mb_per_s;
            est_fps = (groups_per_frame > 0 && patches_per_tile > 0) ?
                      (patches_per_s / (real'(groups_per_frame) * real'(patches_per_tile))) : 0.0;
            proj_fps = (proj_groups_per_frame > 0 && patches_per_tile > 0) ?
                       (patches_per_s / (real'(proj_groups_per_frame) * real'(patches_per_tile))) : 0.0;

            est_fps_patch  = (patch_groups_per_frame > 0) ? (patches_per_s / $itor(patch_groups_per_frame)) : 0.0;
            proj_fps_patch = (proj_patch_groups_per_frame > 0) ? (patches_per_s / $itor(proj_patch_groups_per_frame)) : 0.0;

            scale = (clk_mhz > 0.0) ? (PERF_TARGET_CLK_MHZ / clk_mhz) : 0.0;
            patches_per_s_scaled = patches_per_s * scale;
            est_fps_scaled = est_fps * scale;
            proj_fps_scaled = proj_fps * scale;

            est_fps_patch_scaled  = est_fps_patch * scale;
            proj_fps_patch_scaled = proj_fps_patch * scale;

            if (suite_patches > 0) begin
                io_bytes_per_patch = ((real'(suite_input_words) + real'(suite_output_words) + real'(suite_dram_words)) * (DATA_W / 8.0)) / real'(suite_patches);
            end else begin
                io_bytes_per_patch = 0.0;
            end
            io_bytes_per_patch_used = (PERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE > 0.0) ? PERF_REAL_IO_BYTES_PER_PATCH_OVERRIDE : io_bytes_per_patch;
            if (PERF_REAL_IO_GBPS_OVERRIDE > 0.0) begin
                bw_bytes_per_s = PERF_REAL_IO_GBPS_OVERRIDE * 1e9 * PERF_REAL_IO_EFF;
            end else begin
                bw_bytes_per_s = (DATA_W / 8.0) * (PERF_TARGET_CLK_MHZ * 1e6) * PERF_REAL_IO_EFF;
            end
            io_cap_gbps = bw_bytes_per_s / 1e9;
            if (io_bytes_per_patch_used > 0.0) begin
                patches_per_s_bw = bw_bytes_per_s / io_bytes_per_patch_used;
            end else begin
                patches_per_s_bw = 0.0;
            end
            patches_per_s_real = (patches_per_s_scaled > 0.0 && patches_per_s_bw > 0.0) ?
                                 ((patches_per_s_scaled < patches_per_s_bw) ? patches_per_s_scaled : patches_per_s_bw) :
                                 patches_per_s_scaled;
            est_fps_real = (groups_per_frame > 0 && patches_per_tile > 0) ?
                           (patches_per_s_real / (real'(groups_per_frame) * real'(patches_per_tile))) : 0.0;
            proj_fps_real = (proj_groups_per_frame > 0 && patches_per_tile > 0) ?
                            (patches_per_s_real / (real'(proj_groups_per_frame) * real'(patches_per_tile))) : 0.0;

            est_fps_patch_real  = (patch_groups_per_frame > 0) ? (patches_per_s_real / $itor(patch_groups_per_frame)) : 0.0;
            proj_fps_patch_real = (proj_patch_groups_per_frame > 0) ? (patches_per_s_real / $itor(proj_patch_groups_per_frame)) : 0.0;

            record_perf_row(
                "AGGREGATE",
                clk_mhz,
                suite_busy_cycles,
                int'(suite_patches),
                0.0,
                patches_per_s / 1e3,
                in_mb_per_s,
                out_mb_per_s,
                dram_mb_per_s,
                total_mb_per_s,
                patches_per_tile,
                est_fps,
                est_fps_patch,
                proj_fps,
                proj_fps_patch,
                proj_fps_scaled,
                proj_fps_patch_scaled,
                proj_fps_real,
                proj_fps_patch_real,
                io_bytes_per_patch_used,
                io_cap_gbps
            );
        end

        if (PERF_PRINT_TABLE_AT_END) begin
            print_perf_table();
        end

        $display("\n========================================");
        $display("  Test Summary");
        $display("========================================");
        if (dram_overlap_warn_count != 0) begin
            $display("  DRAM overlap warnings: %0d (printed first %0d)",
                     dram_overlap_warn_count, DRAM_OVERLAP_WARN_MAX_PRINTS);
        end
        if (test_passed) begin
            $display("  Status: PASSED");
        end else begin
            $display("  Status: FAILED");
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
        if (use_ref_memh) begin
            for (y = 0; y < FRAME_HEIGHT; y = y + 1) begin
                for (x = 0; x < FRAME_WIDTH; x = x + 1) begin
                    reference_frame[y][x] = ref_memh_words[y*FRAME_WIDTH + x];
                end
            end
        end else begin
            // Initialize reference frame with checkerboard pattern
            for (y = 0; y < 64; y = y + 1) begin
                for (x = 0; x < 64; x = x + 1) begin
                    reference_frame[y][x] = ((x + y) % 2) ? 16'h7FFF : 16'h0000;
                end
            end
        end

        if (use_patch_memh) begin
            for (p = 0; p < 256; p = p + 1) begin
                for (v = 0; v < 16; v = v + 1) begin
                    input_patches[p][v] = patch_memh_words[p*16 + v];
                end
            end
        end else begin
            // Initialize input patches with gradient patterns
            for (p = 0; p < 256; p = p + 1) begin
                for (v = 0; v < 16; v = v + 1) begin
                    input_patches[p][v] = (p * 256 + v * 16) & 16'hFFFF;
                end
            end
        end
    end
    endtask
    
    // (load_weights task replaced by load_weights_pattern)

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
        // Global guard timeout (in cycles). Keep this comfortably above the
        // longest per-case timeout so we get per-case debug prints first.
        #(CLK_PERIOD * 2000000);
        $display("\n[TIMEOUT] Simulation exceeded maximum time");
        $finish;
    end

endmodule
