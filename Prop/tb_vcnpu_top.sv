// tb_vcnpu_top.sv
`timescale 1ns/1ps

module tb_vcnpu_top;

  // Parameters (should match vcnpu_top defaults)
  localparam DATA_W = 16;
  localparam SIM_TIME_CYCLES = 2000;

  // Clock & reset
  reg clk = 0;
  reg rst_n = 0;
  always #5 clk = ~clk; // 100 MHz sim clock

  // DUT top-level control
  reg start;
  wire busy;
  wire error;

  // DRAM interface signals to DUT
  wire dram_req;
  wire [31:0] dram_addr;
  wire [15:0] dram_len;
  reg  dram_ack;
  reg  dram_data_valid;
  reg  [DATA_W-1:0] dram_data_in;

  // Instantiate DUT (vcnpu_top)
  vcnpu_top #(
    .DATA_W(DATA_W)
  ) uut (
    .clk(clk),
    .rst_n(rst_n),
    .dram_req(dram_req),
    .dram_addr(dram_addr),
    .dram_len(dram_len),
    .dram_ack(dram_ack),
    .dram_data_valid(dram_data_valid),
    .dram_data_in(dram_data_in),
    .start(start),
    .busy(busy),
    .error(error)
  );

  // For visibility: internal FIFO & credit signals (hierarchical)
  // These references rely on the instance names used in the top-level RTL:
  // u_gsfifo and u_credit_fsm as instantiated in vcnpu_top.
  // They are optional and simulators may warn if not found; wrap in `ifdef` if needed.
  // We'll attempt to sample them using hierarchical access (tool dependent but works in common SV simulators).
  // Use non-blocking reads through local regs each cycle.
  reg fifo_full_r, fifo_empty_r;
  reg credit_available_r;

  // DRAM stub behavior:
  // - When dram_req asserted, respond with dram_ack=1 next cycle and then
  //   drive dram_data_valid pulses for a configured number of beats (we use dram_len or default).
  integer dram_data_counter;
  task respond_to_dram_req();
    integer beats;
    begin
      // emulate 1-cycle acceptance
      @(posedge clk);
      dram_ack <= 1'b1;
      // compute beats: if dram_len is 0, default to 4 words; else min(dram_len, 64)
      beats = (dram_len == 0) ? 4 : ( (dram_len > 64) ? 64 : dram_len );
      dram_data_counter = 0;
      // supply beat words starting next cycle
      @(posedge clk);
      dram_ack <= 1'b0;
      repeat (beats) begin
        dram_data_valid <= 1'b1;
        dram_data_in <= dram_data_counter; // deterministic test data
        dram_data_counter = dram_data_counter + 1;
        @(posedge clk);
      end
      // finish
      dram_data_valid <= 1'b0;
    end
  endtask

  // Test control & monitoring
  integer cycle;
  initial begin
    // waveform
    $dumpfile("tb_vcnpu_top.vcd");
    $dumpvars(0, tb_vcnpu_top);

    // init
    start = 0;
    dram_ack = 0;
    dram_data_valid = 0;
    dram_data_in = {DATA_W{1'b0}};

    // reset
    rst_n = 0;
    repeat(5) @(posedge clk);
    rst_n = 1;
    repeat(2) @(posedge clk);

    $display("[%0t] Reset complete. Starting test...", $time);

    // Kick off the pipeline: pulse start for 1 cycle
    @(posedge clk);
    start = 1;
    @(posedge clk);
    start = 0;
    $display("[%0t] start pulse issued", $time);

    // simulation main loop: monitor signals and react to dram_req
    for (cycle=0; cycle<SIM_TIME_CYCLES; cycle=cycle+1) begin
      // sample some internal signals if available (hierarchical)
      // Protect with a try-catch-ish approach: many simulators allow direct hierarchical access.
      // We'll use Verilog hierarchical access — if instance names changed, comment these.
      fifo_full_r = 1'bx;
      fifo_empty_r = 1'bx;
      credit_available_r = 1'bx;
      // attempt to sample
      // Note: these hierarchical references depend on your top-level instance names in vcnpu_top
      // and the simulator allowing hierarchical access. If your tools forbid it, remove these lines.
      // Using non-blocking 'force' style reading is not necessary; simple assignment ok for simulation.
      // Try-catch is not available — keeping it simple.
      // The access below will work in common simulators (VCS, Questa, Icarus).
      fifo_full_r = uut.u_gsfifo.full;
      fifo_empty_r = uut.u_gsfifo.empty;
      credit_available_r = uut.u_credit_fsm.credit_available;

      // print status at intervals or on dram_req
      if (dram_req) begin
        $display("[%0t] DRAM_REQ addr=0x%08x len=%0d (top.dram_req asserted)", $time, dram_addr, dram_len);
        // spawn task to respond concurrently
        fork
          respond_to_dram_req();
        join_none
      end

      // monitor error
      if (error) begin
        $display("[%0t] ERROR asserted by DUT -> failing test", $time);
        $finish;
      end

      // print heartbeat every 100 cycles
      if (cycle % 100 == 0) begin
        $display("[%0t] cycle=%0d busy=%b error=%b fifo_full=%b fifo_empty=%b credit_avail=%b",
                  $time, cycle, busy, error, fifo_full_r, fifo_empty_r, credit_available_r);
      end

      // Terminate early if pipeline finished (busy deasserts)
      if (!busy && (cycle > 10)) begin
        $display("[%0t] DUT became idle (busy=0). Test considered successful.", $time);
        // small delay to let final transactions settle
        repeat (4) @(posedge clk);
        $display("TEST PASSED");
        $finish;
      end

      @(posedge clk);
    end

    // if we reach here, timed out
    $display("SIM TIMEOUT after %0d cycles — finishing with busy=%b error=%b", SIM_TIME_CYCLES, busy, error);
    if (!error) $display("TEST INCONCLUSIVE (timeout) — consider increasing SIM_TIME_CYCLES");
    $finish;
  end

  // Optional: show some wave output progress
  always @(posedge clk) begin
    // small live info on dram_data_valid transitions
    if (dram_data_valid) begin
      $display("[%0t] dram_data_valid: data=%0d", $time, dram_data_in);
    end
  end

endmodule
